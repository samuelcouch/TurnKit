# frozen_string_literal: true

# Shared by the memory and PostgreSQL background suites. Model responses are
# synthetic; tool execution, fencing, receipts and reconciliation are real.
module BudgetCompletion
  class Save < TurnKit::Tool
    tool_name "budget_save"
    parameter :value, :string, required: true
    terminal! { |result| "Saved #{result.fetch('value')}." }
    recovery :replay_safe
    budget_completion!
    attr_reader :attempts, :effects
    attr_accessor :before_save, :after_save

    def initialize
      @attempts, @effects = [], {}
    end

    def call(value:, context:)
      @attempts << context.idempotency_key
      before_save&.call(context)
      result = @effects[context.idempotency_key] ||= { "value" => value }
      after_save&.call(context)
      result
    end
  end

  def test_budget_completion_requires_explicit_terminal_and_replay_safe_contract
    tool = Class.new(TurnKit::Tool) { tool_name "unsafe_save"; budget_completion! }
    assert_raises(ArgumentError) { register("unsafe_save", tools: [tool]) }
    tool.terminal!
    assert_raises(ArgumentError) { register("unsafe_save", tools: [tool]) }
    tool.recovery :replay_safe
    assert tool.validate_definition!
    refute Class.new(TurnKit::Tool) { terminal! }.budget_completion?
  end

  def test_budget_completion_mixed_order_exact_limit_and_overrun
    [0.01, 0.02].product([false, true]).each do |cost, save_first|
      save, acquire = Save.new, self.class::CountingTool.new
      calls = [budget_call("fetch", "counting"), budget_call("save"), budget_call("fetch2", "counting")]
      calls.rotate! if save_first
      client = FakeClient.new(budget_response(calls, cost: cost))
      run = register("handoff_#{cost}_#{save_first}", client: client, tools: [save, acquire], max_spend: 0.01,
        max_tool_executions: 1, max_tool_executions_by_name: { "counting" => 0 }).run("work", async: true).perform_later
      drain_jobs
      assert run.reload.completed?, run.error.inspect
      assert_equal "Saved packet.", run.output_text
      assert_equal cost, run.cost.total
      assert_equal 1, client.calls.length
      assert_equal 1, save.effects.length
      assert_equal 0, acquire.calls
      assert_equal({ "fetch" => "cancelled", "save" => "completed", "fetch2" => "cancelled" },
        run.tool_executions.to_h { |execution| [execution.tool_call_id, execution.status] })
      assert run.tool_executions.select(&:cancelled?).all? { |execution| execution.result.fetch("message") == "not executed: spend limit reached" }
      results = run.turn.conversation.messages.select(&:tool_result?).flat_map(&:content)
      assert_equal %w[fetch fetch2 save], results.map { |part| part.fetch("tool_call_id") }.sort
      assert_equal "save", TurnKit.store.load_turn(run.id).dig("options", "state", "budget_completion_call_id")
    end
  end

  def test_budget_completion_below_limit_keeps_normal_order
    save, acquire = Save.new, self.class::CountingTool.new
    client = FakeClient.new(budget_response([budget_call("fetch", "counting"), budget_call("save")], cost: 0.009))
    run = register("below_bound", client: client, tools: [save, acquire], max_spend: 0.01).run("work")
    assert run.completed?
    assert_equal 1, acquire.calls
    assert_equal 1, save.effects.length
    assert_nil TurnKit.store.load_turn(run.id).dig("options", "state", "budget_completion_call_id")
  end

  def test_budget_completion_no_opt_in_no_save_or_ambiguous_save_fail_without_dispatch
    ordinary = Class.new(Save) { tool_name "ordinary_save"; terminal! }
    [[], [budget_call("fetch", "counting")], [budget_call("plain", "ordinary_save")],
      [budget_call("one"), budget_call("two")]].each_with_index do |calls, index|
      save, plain, acquire = Save.new, ordinary.new, self.class::CountingTool.new
      client = FakeClient.new(budget_response(calls, cost: 0.02))
      run = register("no_handoff_#{index}", client: client, tools: [save, plain, acquire], max_spend: 0.01).run("work", async: true).perform_later
      drain_jobs
      assert run.reload.failed?
      assert_equal "cost limit reached", run.error.fetch("message")
      assert_equal 0.02, run.cost.total
      assert_empty save.attempts + plain.attempts
      assert_equal 0, acquire.calls
      TurnKit::Background.reconcile
      drain_jobs
      assert_equal 1, client.calls.length
    end
  end

  def test_budget_completion_recovery_at_response_and_receipt_commit_boundaries
    %w[model.completed tool_call.completed].each do |boundary|
      save = Save.new
      client = FakeClient.new(budget_response([budget_call("save")]))
      run = register("crash_#{boundary}", client: client, tools: [save], max_spend: 0.01).run("work", async: true).perform_later
      TurnKit.on_event = ->(event) { raise IOError, "worker died after commit" if event.type == boundary }
      assert_raises(IOError) { TurnKit::Background.perform(run.id) }
      row = TurnKit.store.load_turn(run.id)
      assert_equal "save", row.dig("options", "state", "budget_completion_call_id")
      assert_equal "tools", row.dig("options", "state", "phase")
      assert_equal 0.02, row.fetch("cost")
      TurnKit.on_event = nil
      expire(run)
      TurnKit::Background.reconcile
      drain_jobs
      assert run.reload.completed?
      assert_equal 1, save.attempts.length
      assert_equal 1, save.effects.length
      assert_equal 1, client.calls.length
      assert_equal 1, run.tool_executions.length
      assert_equal 1, run.turn.conversation.messages.count(&:tool_result?)
    end
  end

  def test_budget_completion_replays_only_unfinished_idempotent_save
    save = Save.new
    save.after_save = ->(_) { raise IOError, "worker died after local commit" if save.attempts.length <= 2 }
    client = FakeClient.new(budget_response([budget_call("save")]))
    run = register("save_recovery", client: client, tools: [save], max_spend: 0.01).run("work", async: true).perform_later
    2.times do
      assert_raises(IOError) { TurnKit::Background.perform(run.id) }
      expire(run)
      TurnKit::Background.reconcile
    end
    drain_jobs
    assert run.reload.completed?
    assert_equal 3, save.attempts.length
    assert_equal 1, save.attempts.uniq.length
    assert_equal 1, save.effects.length
    assert_equal 1, client.calls.length
    assert_equal 1, run.tool_executions.length
  end

  def test_budget_completion_invalid_or_unauthorized_save_never_retries_or_repairs_with_model
    [:arguments, :validation, :authorization].each do |failure|
      save = Save.new
      save.before_save = ->(_) { raise TurnKit::ToolValidationError, "invalid packet" } if failure == :validation
      args = failure == :arguments ? {} : { value: "packet" }
      client = FakeClient.new(budget_response([budget_call("save", "budget_save", args)]))
      run = register("invalid_#{failure}", client: client, tools: [save], max_spend: 0.01).run("work", async: true).perform_later
      TurnKit.authorization_policy = ->(action, **) { action != :tool } if failure == :authorization
      # Lose the worker after the failed receipt commits; that failed call must
      # not be converted back to pending or invoked again on reconciliation.
      TurnKit.on_event = ->(event) { raise IOError, "worker died after failed receipt" if event.type == "tool_call.failed" }
      assert_raises(IOError) { TurnKit::Background.perform(run.id) }
      assert run.tool_executions.first.failed?
      attempts = save.attempts.length
      TurnKit.on_event = nil
      TurnKit.authorization_policy = nil
      expire(run)
      TurnKit::Background.reconcile
      drain_jobs
      assert run.reload.failed?
      assert_equal attempts, save.attempts.length
      assert_empty save.effects
      assert_equal 1, client.calls.length
      assert_equal 1, run.tool_executions.length
      assert_equal 1, run.turn.conversation.messages.count(&:tool_result?)
    end
  end

  def test_budget_completion_pause_resume_cancellation_and_steering
    [:pause, :cancel, :steer].each do |control|
      save = Save.new
      client = FakeClient.new(budget_response([budget_call("save")]))
      run = register("handoff_#{control}", client: client, tools: [save], max_spend: 0.01).run("work", async: true).perform_later
      TurnKit.on_event = lambda do |event|
        next unless event.type == "model.completed"
        control == :steer ? run.steer!("different task", key: "new") : run.public_send("#{control}!")
      end
      drain_jobs
      TurnKit.on_event = nil
      if control == :pause
        assert run.reload.paused?
        assert_empty save.attempts
        TurnKit.load_turn(run.id).resume!
        drain_jobs
        assert run.reload.completed?
        assert_equal 1, save.effects.length
      else
        assert_equal control == :cancel ? "cancelled" : "failed", run.reload.status
        assert_empty save.attempts
      end
      assert_equal 1, client.calls.length
    end
  end

  def test_budget_completion_cannot_write_with_revoked_claim
    save = Save.new
    save.before_save = lambda do |context|
      context.turn.cancel!
      context.turn.conversation.say("late write")
    end
    client = FakeClient.new(budget_response([budget_call("save")]))
    run = register("handoff_fence", client: client, tools: [save], max_spend: 0.01).run("work", async: true).perform_later
    drain_jobs
    assert run.reload.cancelled?
    assert_empty save.effects
    refute run.tool_executions.first.completed?
    refute run.turn.conversation.messages.any? { |message| message.text == "late write" }
    assert_equal 1, client.calls.length
  end

  def test_budget_completion_still_enforces_tool_limits_and_timeout
    [{ max_tool_executions: 0 }, { max_tool_executions_by_name: { "budget_save" => 0 } }, { timeout: 1 }].each_with_index do |limits, index|
      save = Save.new
      client = FakeClient.new(budget_response([budget_call("save")]))
      run = register("handoff_limit_#{index}", client: client, tools: [save], max_spend: 0.01, **limits).run("work", async: true).perform_later
      if limits[:timeout]
        TurnKit.on_event = lambda do |event|
          TurnKit.store.update_turn(run.id, submitted_at: TurnKit::Clock.now - 2) if event.type == "model.completed"
        end
      end
      drain_jobs
      TurnKit.on_event = nil
      assert run.reload.failed?
      assert_empty save.effects
      assert_equal 1, client.calls.length
    end
  end

  def test_budget_completion_cannot_make_internal_model_calls_or_model_policy_repairs
    [:tool_model, :tool_image, :tool_media, :policy_model, :local_policy].each do |mode|
      save, auditor = Save.new, FakeClient.new
      options = {}
      if mode == :tool_model
        save.before_save = ->(context) { context.turn.internal_model_call(model: "test-model", messages: [], instructions: "extra", purpose: "extra", client: auditor) }
      elsif mode == :tool_image
        save.before_save = ->(context) { context.turn.paint("extra", model: "test-model", client: auditor) }
      elsif mode == :tool_media
        save.before_save = ->(context) { context.turn.view_media("https://example.com/test.png", objective: "extra", model: "test-model", client: auditor) }
      elsif mode == :policy_model
        options[:output_policy] = TurnKit::OutputPolicy.new(content: "check output", client: auditor)
      else
        options[:output_policy] = ->(_) { "invalid output" }
        options[:output_retries] = 3
      end
      client = FakeClient.new(budget_response([budget_call("save")]))
      run = register("handoff_policy_#{mode}", client: client, tools: [save], max_spend: 0.01, **options).run("work", async: true).perform_later
      drain_jobs
      assert run.reload.failed?
      assert_empty auditor.calls
      assert_equal 1, client.calls.length
    end
  end

  def test_budget_completion_does_not_waive_late_model_or_ordinary_tool_dispatch_checks
    [:model, :tool].each do |boundary|
      acquire = self.class::CountingTool.new
      client = FakeClient.new(budget_response([budget_call("fetch", "counting")], cost: 0.009))
      run = register("late_bound_#{boundary}", client: client, tools: [acquire], max_spend: 0.01).run("work", async: true).perform_later
      if boundary == :model
        TurnKit.on_event = lambda do |event|
          TurnKit.store.update_turn(run.id, cost: 0.01) if event.type == "model.requested"
        end
      else
        TurnKit.authorization_policy = lambda do |action, **|
          TurnKit.store.update_turn(run.id, cost: 0.01) if action == :tool
          true
        end
      end
      drain_jobs
      TurnKit.on_event = nil
      TurnKit.authorization_policy = nil
      assert run.reload.failed?
      assert_equal 0, acquire.calls
      assert_equal boundary == :model ? 0 : 1, client.calls.length
    end
  end

  def test_exact_spend_exhaustion_blocks_dispatch_and_reconstitutes_on_resume
    client = FakeClient.new
    run = register("already_exhausted", client: client, max_spend: 0.01).run("work", async: true).perform_later
    TurnKit.store.update_turn(run.id, cost: 0.01)
    drain_jobs
    assert run.reload.failed?
    assert_empty client.calls
    budget = run.turn.execution_budget
    assert budget.spend_exhausted?
    assert_raises(TurnKit::BudgetError) { budget.check!(depth: 0) }
  end

  private
    def budget_call(id, name = "budget_save", arguments = nil)
      TurnKit::ToolCall.new(id: id, name: name, arguments: arguments || (name == "budget_save" ? { value: "packet" } : {}))
    end

    def budget_response(calls, cost: 0.02)
      TurnKit::Result.new(text: "candidate", tool_calls: calls, usage: TurnKit::Usage.new(cost: cost))
    end
end
