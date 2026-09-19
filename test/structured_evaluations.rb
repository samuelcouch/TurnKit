# frozen_string_literal: true

# Executed against MemoryStore and real PostgreSQL by BackgroundTest subclasses.
module StructuredEvaluations
  class Evaluator < TurnKit::Adapters::CloudflareJev
    attr_reader :calls
    attr_accessor :during_call, :responses

    def initialize
      super(account_id: "fixture", api_token: "never-sent")
      @calls, @responses = [], []
    end

    def evaluate(**request)
      @calls << request
      during_call&.call
      response = responses.shift
      raise response if response.is_a?(Exception)
      response || TurnKit::EvaluationResult.new(model: "jev-fixture", answers: { "support" => { "type" => "noul", "noul" => 0.73 } },
        usage: TurnKit::Usage.new(input_tokens: 137, output_tokens: 29))
    end
  end

  def evaluation_options(evaluator, **options)
    { evaluator: evaluator, model: "typesafe/jev", purpose: :evidence, policy_version: "v1",
      state: { "context" => "bounded original text" },
      questions: { "support" => { "type" => "noul", "instructions" => "Supported?" } } }.merge(options)
  end

  def evaluation_agent(policy, **options)
    TurnKit.cost_rates["cloudflare/typesafe/jev"] = { input: 2, output: 3 }
    register("evaluated", output_policy: policy, **options)
  end

  def test_evaluation_receipt_reuse_and_changed_semantics
    evaluator = Evaluator.new
    ids = []
    policy = ->(output, turn:) do
      options = evaluation_options(evaluator, candidate: output)
      ids << turn.internal_evaluation(**options).receipt_id
      ids << turn.internal_evaluation(**options).receipt_id
      ids << turn.internal_evaluation(**options.merge(policy_version: "v2")).receipt_id
      ids << turn.internal_evaluation(**options.merge(candidate: "different")).receipt_id
      turn.output_metadata = { "assessment" => "signals", "receipt_id" => ids.first }
      nil
    end
    run = evaluation_agent(policy).run("work")
    assert run.completed?, run.error.inspect
    assert_equal 3, evaluator.calls.size
    assert_equal ids[0], ids[1]
    assert_equal 3, ids.uniq.size
    assert_equal 411, run.usage.input_tokens
    assert_equal 87, run.usage.output_tokens
    assert_in_delta 0.001083, run.cost.total, 1e-9
    assert_equal 1, run.messages.count { |m| m.role == "assistant" }
    assert_equal "signals", TurnKit::SubAgentTool.result(TurnKit.store.load_turn(run.id)).dig("output_metadata", "assessment")
  end

  def test_evaluation_commit_crash_reuses_receipt_without_duplicate_accounting_or_revision
    evaluator = Evaluator.new
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator)); nil }
    run = evaluation_agent(policy).run("work", async: true).perform_later
    TurnKit.on_event = ->(event) { raise IOError, "crash after receipt" if event.type == "evaluation.completed" }
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    assert_equal 137, run.reload.usage.input_tokens
    TurnKit.on_event = nil
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?, run.error.inspect
    assert_equal 1, evaluator.calls.size
    assert_equal 137, run.usage.input_tokens
  end

  def test_evaluation_revision_commit_crash_does_not_repeat_the_repair
    evaluator = Evaluator.new
    policy = ->(output, turn:) do
      turn.internal_evaluation(**evaluation_options(evaluator))
      "repair the unsupported field" if output == "draft"
    end
    client = FakeClient.new(TurnKit::Result.new(text: "draft"), TurnKit::Result.new(text: "revised"))
    run = evaluation_agent(policy, client: client, output_retries: 1).run("work", async: true).perform_later
    TurnKit.on_event = ->(event) { raise IOError, "crash after revision commit" if event.type == "output_policy.revision" }
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    TurnKit.on_event = nil
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?, run.error.inspect
    assert_equal 2, client.calls.size
    assert_equal 2, evaluator.calls.size
    assert_equal 274, run.usage.input_tokens
    assert_equal 1, run.messages.count { |message| message.metadata["source"] == "output_policy" }
  end

  def test_evaluation_usage_and_receipt_roll_back_together
    evaluator = Evaluator.new
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator)); nil }
    run = evaluation_agent(policy).run("work", async: true).perform_later
    store = TurnKit.store
    original = store.method(:update_turn)
    store.define_singleton_method(:update_turn) do |id, attributes|
      value = original.call(id, attributes)
      receipts = attributes.dig(:options, "state", "evaluations")
      raise IOError, "commit failed" if receipts&.values&.any? { |receipt| receipt["status"] == "completed" }
      value
    end
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    assert_equal 0, run.reload.usage.input_tokens
    receipt = run.turn.evaluation_receipts.values.fetch(0)
    assert_equal "uncertain", receipt["status"]
    assert_nil receipt["attempts"].first["cost"]
    assert run.cost.unknown?
    assert_nil run.cost.total
  ensure
    store&.define_singleton_method(:update_turn, original) if original
  end

  def test_evaluation_no_http_in_transaction_and_cancelled_response_is_fenced
    evaluator = Evaluator.new
    run = nil
    evaluator.during_call = lambda do
      store = TurnKit.store
      if store.is_a?(TurnKit::ActiveRecordStore)
        assert_equal 0, ActiveRecord::Base.connection.open_transactions
      else
        assert_equal 0, store.instance_variable_get(:@transaction_depth)
      end
      row = store.load_turn(run.id)
      assert_equal "uncertain", row.dig("options", "state", "evaluations").values.first["status"]
      TurnKit.load_turn(run.id).cancel!
    end
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator)); nil }
    run = evaluation_agent(policy).run("work", async: true).perform_later
    TurnKit::Background.perform(run.id)
    assert run.reload.cancelled?
    assert_equal 0, run.usage.input_tokens
    assert_nil run.cost.total
    assert_equal "uncertain", run.turn.evaluation_receipts.values.first["status"]
  end

  def test_evaluation_retry_usage_and_unknown_cost_are_not_hidden
    evaluator = Evaluator.new
    evaluator.responses = [TurnKit::EvaluationError.new(:uncertain, retryable: true, retry_after: 0,
      usage: TurnKit::Usage.new(input_tokens: 19, output_tokens: 7), model: "jev-fixture")]
    checks = 0
    policy = ->(_output, turn:) do
      turn.internal_evaluation(**evaluation_options(evaluator, max_attempts: 2,
        before_dispatch: ->(**_) { checks += 1 }))
      nil
    end
    run = evaluation_agent(policy).run("work")
    assert run.completed?, run.error.inspect
    assert_equal 2, checks
    assert_equal 156, run.usage.input_tokens
    assert_equal 36, run.usage.output_tokens
    assert_in_delta 0.000420, run.cost.total, 1e-9
    assert_equal ["uncertain", "completed"], run.turn.evaluation_receipts.values.first["attempts"].map { |a| a["status"] }
  end

  def test_evaluation_default_does_not_replay_unknown_network_execution_after_crash
    evaluator = Evaluator.new
    evaluator.during_call = -> { raise IOError, "process died after dispatch" }
    policy = ->(_output, turn:) do
      begin
        turn.internal_evaluation(**evaluation_options(evaluator))
      rescue TurnKit::EvaluationError => error
        turn.output_metadata = { "assessment" => error.status }
      end
      nil
    end
    run = evaluation_agent(policy).run("work", async: true).perform_later
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    evaluator.during_call = nil
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?, run.error.inspect
    assert_equal 1, evaluator.calls.size
    assert_equal "uncertain", run.turn.output_metadata["assessment"]
    assert run.cost.unknown?
  end

  def test_evaluation_transport_policy_and_root_budget_block_retries
    evaluator = Evaluator.new
    evaluator.responses = [TurnKit::EvaluationError.new(:uncertain, retryable: true, retry_after: 0,
      usage: TurnKit::Usage.new(input_tokens: 10_000), model: "jev-fixture")]
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator, max_attempts: 2)); nil }
    run = evaluation_agent(policy, max_spend: 0.01).run("work")
    assert run.failed?
    assert_equal "cost limit reached", run.error["message"]
    assert_equal 1, evaluator.calls.size
    assert_in_delta 0.02, run.cost.total, 1e-9

    evaluator = Evaluator.new
    policy = ->(_output, turn:) do
      turn.internal_evaluation(**evaluation_options(evaluator, before_dispatch: ->(**_) { raise TurnKit::AuthorizationError, "denied" }))
    end
    run = evaluation_agent(policy).run("work")
    assert run.failed?
    assert_empty evaluator.calls
  end

  def test_evaluation_deadline_accounts_late_response_but_does_not_use_it
    evaluator = Evaluator.new
    evaluator.during_call = -> { sleep 0.03 }
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator, timeout: 0.01)); nil }
    run = evaluation_agent(policy).run("work")
    assert run.failed?
    assert_equal "evaluation deadline exceeded", run.error["message"]
    assert_equal 137, run.usage.input_tokens
  end

  def test_evaluation_retry_after_does_not_cross_remaining_deadline
    evaluator = Evaluator.new
    evaluator.responses = [TurnKit::EvaluationError.new(:unavailable, retryable: true, retry_after: 60)]
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator, timeout: 1, max_attempts: 2)); nil }
    run = evaluation_agent(policy).run("work")
    assert run.failed?
    assert_equal "evaluation deadline exceeded", run.error["message"]
    assert_equal 1, evaluator.calls.size
    assert run.cost.unknown?
  end

  def test_evaluation_uncertain_recovery_retries_only_when_explicitly_enabled
    evaluator = Evaluator.new
    evaluator.during_call = -> { raise IOError, "worker died" }
    policy = ->(_output, turn:) { turn.internal_evaluation(**evaluation_options(evaluator, max_attempts: 2)); nil }
    run = evaluation_agent(policy).run("work", async: true).perform_later
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    evaluator.during_call = nil
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?, run.error.inspect
    assert_equal 2, evaluator.calls.size
    assert_equal 137, run.usage.input_tokens
    assert_nil run.cost.total, "unobserved first attempt is not free"
    attempts = run.turn.evaluation_receipts.values.first["attempts"]
    assert_equal 2, attempts.size
    assert_nil attempts.first["cost"]
    assert_in_delta 0.000361, attempts.last["cost"], 1e-9
  end

  def test_evaluation_completed_receipt_can_be_read_after_it_exhausts_spend
    evaluator = Evaluator.new
    policy = ->(_output, turn:) do
      options = evaluation_options(evaluator)
      first = turn.internal_evaluation(**options)
      assert_equal first.receipt_id, turn.internal_evaluation(**options).receipt_id
      assert_raises(TurnKit::BudgetError) { turn.internal_evaluation(**options.merge(policy_version: "new")) }
      nil
    end
    run = evaluation_agent(policy, max_spend: 0.0003).run("work")
    assert run.completed?, run.error.inspect
    assert_equal 1, evaluator.calls.size
  end

  def test_evaluation_obeys_parent_spend_and_authorization_without_changing_chat_policy
    evaluator = Evaluator.new
    policy = ->(_output, turn:) do
      options = evaluation_options(evaluator)
      turn.internal_evaluation(**options)
      turn.internal_evaluation(**options.merge(policy_version: "new"))
      nil
    end
    child = evaluation_agent(policy, max_spend: 10)
    parent_client = FakeClient.new(TurnKit::Result.new(
      tool_calls: [TurnKit::ToolCall.new(id: "read", name: "evaluated", arguments: { task: "read" })],
      usage: TurnKit::Usage.new(cost: 0.0099)))
    parent = register("limited-parent", client: parent_client, tools: [TurnKit::SubAgentTool.for(child)], max_spend: 0.01)
    run = parent.run("work")
    assert run.failed?
    assert_equal 1, evaluator.calls.size
    assert_equal "cost limit reached", run.tool_executions.first.result.dig("error", "message")

    evaluator = Evaluator.new
    TurnKit.authorization_policy = ->(action, **) { action != :evaluate }
    run = evaluation_agent(policy).run("work")
    assert run.failed?
    assert_empty evaluator.calls
    assert_equal "TurnKit::AuthorizationError", run.error["class"]
  end

  def test_evaluation_child_revision_has_equivalent_inline_and_background_envelopes
    envelopes = []
    TurnKit.cost_rates["test-model"] = { input: 0, output: 0 }
    [false, true].each do |background|
      evaluator = Evaluator.new
      policy = ->(output, turn:) do
        result = turn.internal_evaluation(**evaluation_options(evaluator))
        turn.output_metadata = { "assessment" => output == "draft" ? "repair" : "signals", "model" => result.model }
        "repair the unsupported field" if output == "draft"
      end
      client = FakeClient.new(TurnKit::Result.new(text: "draft", usage: TurnKit::Usage.new(cost: 0.01)),
        TurnKit::Result.new(text: "revised", usage: TurnKit::Usage.new(cost: 0.02)))
      child = evaluation_agent(policy, client: client, output_retries: 1)
      parent_client = FakeClient.new(calls(["child", "evaluated", { task: "bounded evidence" }]), TurnKit::Result.new(text: "synthesis"))
      parent = register("parent_#{background}", client: parent_client, tools: [TurnKit::SubAgentTool.for(child)])
      run = parent.run("work", async: background)
      if background
        run.perform_later
        TurnKit::Background.perform(run.id)
        assert run.reload.waiting?
        assert_equal 1, parent_client.calls.size
        drain_jobs
      end
      assert run.reload.completed?, run.error.inspect
      assert_equal 2, evaluator.calls.size
      assert_equal 2, client.calls.size
      assert_equal 274, run.usage.input_tokens
      assert_in_delta 0.030722, run.cost.total, 1e-9
      result = run.tool_executions.first.result
      assert_equal "revised", result["result"]
      assert_equal "signals", result.dig("output_metadata", "assessment")
      envelopes << result.reject { |key, _| %w[turn_id conversation_id].include?(key) }
      child_row = TurnKit.store.load_turn(result["turn_id"])
      assert_equal 1, child_row.dig("options", "state", "revisions_used")
    end
    assert_equal envelopes.first, envelopes.last
  end
end
