# frozen_string_literal: true

module TurnKit
  module InternalEvaluation
    # Call from a tool or output-audit callable, never from a persistence callback.
    # before_dispatch is application transport/spend policy, not model input.
    def internal_evaluation(evaluator:, model:, purpose:, state:, questions:, policy_version:,
      candidate: nil, max_attempts: 1, timeout: 30, before_dispatch: nil)
      raise LostClaim, "evaluation requires an owned execution" unless store.is_a?(ExecutionStore)
      raise ArgumentError, "max_attempts must be 1..3" unless max_attempts.is_a?(Integer) && (1..3).include?(max_attempts)
      raise ArgumentError, "timeout must be positive and finite" unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
      input = evaluator.validate!(model: model, state: state, questions: questions)
      reload
      identity = Evaluation.json(provider: evaluator.identity, model: model, purpose: purpose.to_s,
        policy_version: policy_version.to_s, candidate: candidate, input: input, schema: 1,
        output_candidate: @record.dig("options", "state", "candidate"),
        output_data: @record.dig("options", "state", "output_data"),
        timeout: timeout, max_attempts: max_attempts)
      key = Digest::SHA256.hexdigest(JSON.generate(identity))
      cost_model = evaluator.cost_model(model: model)
      deadline = Clock.now + timeout
      loop do
        receipt = store.atomic do
          reload
          raise LostClaim, "evaluation requires an owned execution" unless store.is_a?(ExecutionStore) && running?
          (evaluation_receipts[key] || { "id" => key, "model" => model,
            "provider" => identity["provider"], "purpose" => purpose.to_s,
            "policy_version" => policy_version.to_s, "cost_model" => cost_model, "attempts" => [] })
        end
        return EvaluationResult.from_h(receipt.fetch("result"), receipt_id: key) if receipt["status"] == "completed"
        last = receipt["attempts"].last
        if last && (!last["retryable"] || receipt["attempts"].size >= max_attempts)
          raise EvaluationError.new(last.fetch("status"), http_status: last["http_status"])
        end
        if last && last["owner"] == @record["claim_token"] && !last["finished_at"]
          raise EvaluationError.new(:in_progress)
        end
        delay = last ? [last.fetch("retry_at", 0) - Clock.now.to_f, 0].max : 0
        remaining = check_evaluation_dispatch!(deadline)
        raise BudgetError, "evaluation deadline exceeded" if delay >= remaining
        sleep(delay) if delay.positive?
        Authorization.authorize!(:evaluate, principal: @record.dig("options", "principal"),
          turn: self, evaluator: evaluator, model: model, purpose: purpose)
        before_dispatch.call(turn: self, model: model, purpose: purpose) if before_dispatch
        attempt = nil
        remaining = nil
        store.atomic do
          reload
          remaining = check_evaluation_dispatch!(deadline)
          current = evaluation_receipts[key]
          # A second caller may have committed or dispatched while policy ran.
          raise EvaluationError.new(:in_progress) if current && current != receipt
          attempt = { "id" => SecureRandom.uuid, "owner" => @record["claim_token"],
            "status" => "uncertain", "retryable" => true, "started_at" => Clock.now.iso8601(6),
            "cost" => nil }
          receipt["attempts"] << attempt
          receipt["status"] = "uncertain"
          save_evaluation_receipt!(key, receipt)
        end
        event = { receipt_id: key, attempt_id: attempt["id"], model: model, purpose: purpose.to_s,
          question_count: input.fetch("questions").size }
        emit("evaluation.requested", event)
        result = nil
        failure = nil
        begin
          result = evaluator.evaluate(model: model, state: input.fetch("state"),
            questions: input.fetch("questions"), timeout: remaining)
        rescue EvaluationError => error
          failure = error
        end
        observed_usage = result ? result.usage : failure.usage
        observed_cost = Cost.from_usage(observed_usage, model: cost_model) if observed_usage
        store.atomic do
          reload
          attempt.merge!("status" => result ? "completed" : failure.status,
            "finished_at" => Clock.now.iso8601(6), "retryable" => failure&.retryable? || false,
            "http_status" => failure&.http_status,
            "usage" => observed_usage&.to_h, "cost" => observed_cost&.total,
            "returned_model" => result ? result.model : failure.model)
          if failure&.retryable?
            attempt["retry_at"] = Clock.now.to_f + (failure.retry_after || rand * (2 ** (receipt["attempts"].size - 1)))
          end
          receipt["status"] = attempt["status"]
          receipt["result"] = result.to_h if result
          add_usage!(observed_usage, cost: observed_cost) if observed_usage
          save_evaluation_receipt!(key, receipt)
        end
        emit(result ? "evaluation.completed" : "evaluation.failed", event.merge(
          status: attempt["status"], returned_model: attempt["returned_model"], http_status: attempt["http_status"],
          usage: observed_usage&.to_h, cost: observed_cost&.to_h,
          duration: Clock.now - Time.iso8601(attempt["started_at"])))
        # Keep the shared inline budget in sync without turning a paid successful
        # assessment into a retry just because its own cost exhausted the budget.
        begin
          budget.add_cost!(observed_cost&.total)
        rescue BudgetError
          # The next dispatch checks the persisted root ledger.
        end
        root_budget = execution_budget
        root_budget.check!(depth: depth, allow_exhausted_spend: true)
        raise BudgetError, "evaluation deadline exceeded" if Clock.now >= deadline
        return EvaluationResult.from_h(receipt.fetch("result"), receipt_id: key) if result
        raise failure unless failure.retryable? && receipt["attempts"].size < max_attempts
      end
    end

    # Copies, not references to live state. Attempts without usage have unknown
    # cost, even if the turn's known-cost subtotal is zero.
    def evaluation_receipts
      JSON.parse(JSON.generate(@record.dig("options", "state", "evaluations") || {}))
    end

    def output_metadata = JSON.parse(JSON.generate(@record.dig("options", "state", "output_metadata") || {}))

    def output_metadata=(value)
      value = Evaluation.json(value)
      raise InputError, "output metadata must be an object" unless value.is_a?(Hash)
      raise LostClaim, "output metadata requires an owned execution" unless store.is_a?(ExecutionStore)
      store.atomic do
        reload
        raise LostClaim, "output metadata requires an owned execution" unless store.is_a?(ExecutionStore) && running?
        update_state!("output_metadata" => value)
      end
    end

    private
      def save_evaluation_receipt!(key, receipt)
        update_state!("evaluations" => evaluation_receipts.merge(key => receipt))
      end

      def check_evaluation_dispatch!(deadline)
        current_budget = execution_budget
        current_budget.check!(depth: depth)
        raise LostClaim, "evaluation execution is no longer running" unless running?
        raise EvaluationError.new(:interrupted) if @record.dig("options", "controls", "pause_requested")
        root_deadline = current_budget.root_started_at + current_budget.timeout if current_budget.timeout
        remaining = [(deadline - Clock.now), (root_deadline - Clock.now if root_deadline)].compact.min
        raise BudgetError, "evaluation deadline exceeded" unless remaining.positive?
        remaining
      end
  end
end
