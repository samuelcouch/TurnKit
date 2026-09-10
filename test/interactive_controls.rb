# frozen_string_literal: true

# Included in both the memory and PostgreSQL background contract suites.
module InteractiveControls
  def test_steering_interrupts_stale_proposals_but_next_input_stays_frozen
    entered, release = Queue.new, Queue.new
    tool = self.class::CountingTool.new
    client = FakeClient.new(calls(["old", "counting", {}]), TurnKit::Result.new(text: "revised"))
    original = client.method(:chat)
    client.define_singleton_method(:chat) do |**options|
      if calls.empty?
        entered << true
        release.pop
      end
      original.call(**options)
    end
    run = register("interactive", client: client, tools: [tool]).run("work", async: true).perform_later
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { entered.pop }
    conversation = TurnKit.load_turn(run.id).conversation
    delivery = conversation.post("next only", key: "next", principal: "owner")
    TurnKit::Background.deliver(delivery)
    first = run.steer!("focus on debt", key: "one", principal: "owner").first
    assert_equal first, run.steer!("focus on debt", key: "one", principal: "owner").first
    run.steer!("use filings", key: "two", principal: "owner")
    assert_raises(TurnKit::ToolError) { run.steer!("different", key: "one", principal: "owner") }
    assert_equal "pending", conversation.input_status(delivery["id"])["status"]
    release << true
    Timeout.timeout(5) { worker.value }
    assert run.reload.completed?
    assert_equal "revised", run.output_text
    assert_equal 0, tool.calls
    request = client.calls[1]
    assert_equal ["focus on debt", "use filings"], request[:messages].last(2).map { |message| message[:content] }
    refute request[:messages].any? { |message| message[:content] == "next only" }
    assert_equal [:assistant, :tool, :user, :user], request[:messages].last(4).map { |message| message[:role] }
    assert_equal "old", request[:messages][-3][:tool_call_id]
    assert_includes request[:messages][-3][:content], "superseded by human steering"
    inputs = run.control_state.dig("controls", "inputs")
    assert_equal [1, 2], inputs.map { |input| input["sequence"] }
    assert inputs.all? { |input| input["request_id"] == request[:metadata][:request_id] }
    assert_equal 2, conversation.messages.count { |message| message.metadata["steering_id"] }
    drain_jobs
    applied = conversation.input_status(delivery["id"])
    assert_equal "applied", applied["status"]
    refute_equal run.id, applied.dig("application", "turn_id")
    assert_equal client.calls.last[:metadata][:request_id], applied.dig("application", "request_id")
    assert_equal "next only", client.calls.last[:messages].last[:content]
    assert_equal "revised", client.calls.last[:messages][-2][:content]
    # Reconstruct another turn: the earlier delivery must stay at its original
    # application boundary, not move to the end again or split old tool pairs.
    conversation.ask("third task", async: true).perform_later
    drain_jobs
    assert_equal ["revised", "next only", "done", "third task"], client.calls.last[:messages].last(4).map { |message| message[:content] }
    assert_equal ["work", "next only"], conversation.messages.first(2).map(&:text)
  ensure
    release&.push(true)
    worker&.join
  end

  def test_pause_in_flight_model_preserves_candidate_and_usage
    client = self.class::BlockingClient.new("kept")
    run = register("pause_model", client: client).run("work", async: true).perform_later
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { client.entered.pop }
    run.pause!
    assert run.reload.running?
    assert run.control_state.dig("controls", "pause_requested")
    client.release << true
    Timeout.timeout(5) { worker.value }
    assert run.reload.paused?
    assert_nil TurnKit.store.load_turn(run.id)["claim_token"]
    assert_equal "output", TurnKit.store.load_turn(run.id).dig("options", "state", "phase")
    assert_equal "", run.output_text
    TurnKit::Background.reconcile(before: Time.utc(2100))
    drain_jobs
    assert run.reload.paused?
    run.resume!
    run.resume!
    drain_jobs
    assert run.reload.completed?
    assert_equal "kept", run.output_text
    assert_equal 1, client.calls.length
    assert_equal 1, TurnKit::Turn.iterations_for(TurnKit.store.load_turn(run.id))
  ensure
    client&.release&.push(true)
    worker&.join
  end

  def test_pause_tool_commits_result_and_steering_skips_remaining_tool
    entered, release = Queue.new, Queue.new
    tool = self.class::CountingTool.new
    blocking = Class.new(TurnKit::Tool) { tool_name "blocked" }.new
    blocking.define_singleton_method(:call) do |context:|
      entered << true
      release.pop
      { "finding" => "durable finding" }
    end
    client = FakeClient.new(calls(["first", "blocked", {}], ["second", "counting", {}]), TurnKit::Result.new(text: "new plan"))
    run = register("pause_tool", client: client, tools: [blocking, tool]).run("work", async: true).perform_later
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { entered.pop }
    run.pause!
    run.steer!("revise", key: "revise")
    release << true
    Timeout.timeout(5) { worker.value }
    assert run.reload.paused?
    assert_equal 0, tool.calls
    assert_equal "durable finding", run.tool_executions.first.result["finding"]
    run.resume!
    drain_jobs
    assert run.reload.completed?
    assert_equal 0, tool.calls
    assert_equal %w[completed cancelled], run.tool_executions.map(&:status)
    assert_includes client.calls.last[:messages].find { |message| message[:tool_call_id] == "first" }[:content], "durable finding"
  ensure
    release&.push(true)
    worker&.join
  end

  def test_paused_pending_target_accepts_next_input_without_waking
    client = FakeClient.new
    run = register("gate", client: client).run("work", async: true).perform_later.pause!
    conversation = run.turn.conversation
    delivery = conversation.post("later", key: "later")
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.paused?
    assert_empty client.calls
    assert_equal 1, TurnKit.store.list_turns(conversation_id: conversation.id).length
    assert_equal "pending", conversation.input_status(delivery["id"])["status"]
    run.resume!
    drain_jobs
    assert run.reload.completed?
    assert_equal 2, client.calls.length
    refute client.calls.first[:messages].any? { |message| message[:content] == "later" }
    assert_equal "later", client.calls.last[:messages].find { |message| message[:content] == "later" }[:content]
  end

  def test_pause_cascade_join_resume_keeps_findings_and_steers_before_parent_output
    child = register("control_child")
    client = FakeClient.new(calls(["child", "control_child", {task: "find facts"}]), TurnKit::Result.new(text: "revised parent"))
    run = register("control_parent", client: client, sub_agents: [child]).run("work", async: true).perform_later
    TurnKit::Background.perform(run.id)
    assert run.reload.waiting?
    child_turn = TurnKit.load_turn(run.child_turn_records.first.fetch("id"))
    independent = child.run("separate", async: true).perform_later
    run.pause!(descendants: :cascade)
    assert run.reload.paused?
    assert child_turn.reload.paused?
    assert independent.reload.pending?
    run.steer!("new focus", key: "focus", descendants: :cascade)
    drain_jobs
    assert independent.reload.completed?
    run.resume!(descendants: :cascade)
    drain_jobs
    assert run.reload.completed?
    assert child_turn.reload.completed?
    assert_equal "revised parent", run.output_text
    assert_equal "new focus", client.calls.last[:messages].last[:content]
    assert_includes client.calls.last[:messages].find { |message| message[:role] == :tool }[:content], '"result":"done"'
  end

  def test_pause_wait_does_not_lose_dependency_or_reset_deadline
    child = register("deadline_child").run("child", async: true).perform_later
    run = register("deadline_parent", timeout: 10).run("parent", async: true).wait_for(child).perform_later
    run.pause!
    run.resume!
    assert run.reload.waiting?
    run.pause!
    child.pause!
    run.steer!("new task", key: "deadline-steer")
    start = TurnKit.store.load_turn(run.id)["submitted_at"]
    original_clock = TurnKit::Clock.method(:now)
    TurnKit::Clock.define_singleton_method(:now) { start + 11 }
    run.resume!
    drain_jobs
    assert run.reload.failed?
    assert_equal start, TurnKit.store.load_turn(run.id)["submitted_at"]
  ensure
    TurnKit::Clock.define_singleton_method(:now, original_clock) if original_clock
  end

  def test_control_denials_and_cancellation_remain_terminal
    run = register("control_auth").run("work", async: true).perform_later
    TurnKit.authorization_policy = ->(_action, principal:, **) { principal == "owner" }
    assert_raises(TurnKit::AuthorizationError) { run.pause!(principal: "other") }
    assert_raises(TurnKit::AuthorizationError) { run.resume!(principal: "other") }
    assert_raises(TurnKit::AuthorizationError) { run.steer!("no", key: "no", principal: "other") }
    assert_raises(TurnKit::AuthorizationError) { run.control_state(principal: "other") }
    assert_raises(TurnKit::AuthorizationError) { run.turn.conversation.post("no", key: "no", principal: "other") }
    assert_raises(TurnKit::AuthorizationError) { run.turn.conversation.messages_after(0, principal: "other") }
    assert run.reload.pending?
    run.pause!(principal: "owner")
    run.cancel!(principal: "owner")
    run.resume!(principal: "owner")
    run.pause!(principal: "owner")
    assert run.reload.cancelled?
    assert_empty run.control_state(principal: "owner").dig("controls").fetch("inputs", [])
  end

  def test_cursor_catchup_has_conversation_order_without_thinking_parts
    conversation = register("cursor").conversation
    first = conversation.say("first")
    second = conversation.append_message(role: "assistant", kind: "tool_call", content: [
      {"type" => "thinking", "text" => "private reasoning"}, {"type" => "text", "text" => "public"},
      {"type" => "provider", "signature" => "private"}])
    catchup = conversation.messages_after(first.sequence)
    assert_equal [second.id], catchup.map(&:id)
    assert_equal [{"type" => "text", "text" => "public"}], catchup.first.content
    assert_empty conversation.messages_after(second.sequence)
    assert_equal 3, conversation.messages.last.content.length
  end

  def test_pause_before_submission_and_concurrent_resume_claim_once
    client = FakeClient.new
    run = register("prepaused", client: client).run("work", async: true).pause!.perform_later
    drain_jobs
    assert run.reload.paused?
    ready, go = Queue.new, Queue.new
    workers = 2.times.map do
      Thread.new do
        ready << true
        go.pop
        TurnKit.load_turn(run.id).resume!
        TurnKit::Background.perform(run.id)
      end
    end
    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { go << true }
    workers.each { |worker| Timeout.timeout(5) { worker.value } }
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, client.calls.length
  end

  def test_pause_during_child_launch_authorization_prevents_launch
    entered, release = Queue.new, Queue.new
    child = register("launch_race_child")
    client = FakeClient.new(calls(["child", "launch_race_child", {task: "work"}]))
    run = register("launch_race_parent", client: client, sub_agents: [child]).run("work", async: true).perform_later
    TurnKit.authorization_policy = ->(action, **) do
      if action == :launch_agent
        entered << true
        release.pop
      end
      true
    end
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { entered.pop }
    run.pause!(descendants: :cascade)
    release << true
    Timeout.timeout(5) { worker.value }
    assert run.reload.paused?
    assert_empty run.child_turn_records
    TurnKit.authorization_policy = nil
    run.resume!(descendants: :cascade)
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, run.child_turn_records.length
  ensure
    release&.push(true)
    worker&.join
  end

  def test_recovery_keeps_single_steering_message_and_first_request_identity
    client = FakeClient.new
    original = client.method(:chat)
    attempted = false
    client.define_singleton_method(:chat) do |**options|
      unless attempted
        attempted = true
        raise IOError, "worker died after request reservation"
      end
      original.call(**options)
    end
    run = register("steer_recovery", client: client).run("work", async: true).perform_later
    receipt = run.steer!("focus", key: "focus").first
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    applied = run.control_state.dig("controls", "inputs").first
    refute_nil applied["request_id"]
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, run.turn.conversation.messages.count { |message| message.metadata["steering_id"] == receipt["id"] }
    assert_equal applied, run.steer!("focus", key: "focus").first
    assert_raises(TurnKit::Error) { run.steer!("too late", key: "late") }
    assert_equal "focus", client.calls.first[:messages].last[:content]
  end

  def test_reconcile_pause_request_fences_abandoned_model_without_unpausing
    client = self.class::BlockingClient.new("obsolete")
    run = register("pause_recover", client: client).run("work", async: true).perform_later
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { client.entered.pop }
    run.pause!
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.paused?
    client.release << true
    Timeout.timeout(5) { worker.value }
    assert_empty run.turn.conversation.messages.select { |message| message.role == "assistant" }
    run.cancel!
    run.resume!
    assert run.reload.cancelled?
  ensure
    client&.release&.push(true)
    worker&.join
  end

  def test_steering_at_output_publication_boundary
    client = FakeClient.new(TurnKit::Result.new(text: "old"), TurnKit::Result.new(text: "revised"))
    run = register("publication", client: client).run("work", async: true).perform_later
    loaded = TurnKit.load_turn(run.id)
    original = loaded.method(:check_policy)
    requested = false
    loaded.define_singleton_method(:check_policy) do |*args, **options|
      unless requested
        requested = true
        TurnKit.load_turn(id).steer!("revise before publishing", key: "revise")
      end
      original.call(*args, **options)
    end
    loaded.run!
    assert loaded.completed?
    assert_equal "revised", loaded.output_text
    assert_equal 2, client.calls.length
    assert_equal "revise before publishing", client.calls.last[:messages].last[:content]
  end

  def test_resume_racing_child_completion_keeps_parent_join_and_runs_once
    child_client = self.class::BlockingClient.new("child findings")
    child = register("concurrent_child", client: child_client)
    parent_client = FakeClient.new(calls(["join", "concurrent_child", {task: "find"}]), TurnKit::Result.new(text: "joined"))
    run = register("concurrent_parent", client: parent_client, sub_agents: [child]).run("work", async: true).perform_later
    TurnKit::Background.perform(run.id)
    child_id = run.child_turn_records.first.fetch("id")
    worker = Thread.new { TurnKit::Background.perform(child_id) }
    Timeout.timeout(5) { child_client.entered.pop }
    run.pause!
    resume = Thread.new { TurnKit.load_turn(run.id).resume! }
    child_client.release << true
    Timeout.timeout(5) { resume.value; worker.value }
    drain_jobs
    assert run.reload.completed?
    assert_equal "joined", run.output_text
    assert_equal 2, parent_client.calls.length
    assert_includes parent_client.calls.last[:messages].last[:content], "child findings"
  ensure
    child_client&.release&.push(true)
    worker&.join
    resume&.join
  end

  def test_pause_preserves_usage_and_iteration_budget
    client = FakeClient.new(TurnKit::Result.new(text: "candidate", usage: TurnKit::Usage.new(input_tokens: 31, output_tokens: 7)))
    run = register("budget_pause", client: client, max_iterations: 1).run("work", async: true).perform_later
    TurnKit.on_event = ->(event) { TurnKit.load_turn(run.id).pause! if event.type == "model.completed" }
    TurnKit::Background.perform(run.id)
    assert run.reload.paused?
    assert_equal 38, run.usage.total_tokens
    run.steer!("requires another request", key: "budget")
    run.resume!
    drain_jobs
    assert run.reload.failed?
    assert_equal "maximum iterations reached", run.error["message"]
    assert_equal 38, run.usage.total_tokens
    assert_equal 1, client.calls.length
  end

  def test_post_deduplicates_and_preserves_sender_without_replacing_execution_principal
    observed = []
    tool = Class.new(TurnKit::Tool) { tool_name "principal_probe" }.new
    tool.define_singleton_method(:call) do |context:|
      observed << context.principal
      "ok"
    end
    agent = register("post_principal", tools: [tool], client: FakeClient.new(calls(["probe", "principal_probe", {}])))
    conversation = agent.conversation(principal: "executor")
    first = conversation.post("work", key: "post", principal: "sender")
    assert_equal first, conversation.post("work", key: "post", principal: "sender")
    assert_raises(TurnKit::ToolError) { conversation.post("work", key: "post", principal: "other") }
    drain_jobs
    assert_equal ["executor"], observed
    message = conversation.messages.find { |candidate| candidate.metadata["delivery_id"] == first["id"] }
    assert_equal "sender", message.metadata["principal"]
    assert_equal 1, conversation.inbox.length
  end

  def test_cancellation_wins_over_pending_pause_and_steering
    client = self.class::BlockingClient.new("must not publish")
    run = register("cancel_controls", client: client).run("work", async: true).perform_later
    worker = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { client.entered.pop }
    run.pause!
    receipt = run.steer!("change course", key: "course").first
    run.cancel!
    run.resume!
    client.release << true
    Timeout.timeout(5) { worker.value }
    assert run.reload.cancelled?
    assert_equal "", run.output_text
    assert_equal receipt, run.steer!("change course", key: "course").first
    assert_empty run.turn.conversation.messages.select { |message| message.metadata["steering_id"] || message.role == "assistant" }
  ensure
    client&.release&.push(true)
    worker&.join
  end

  def test_cascade_authorization_denial_changes_no_turns
    child = register("denied_control_child")
    run = register("denied_control_parent", sub_agents: [child],
      client: FakeClient.new(calls(["child", "denied_control_child", {task: "work"}]))).run("work", async: true).perform_later
    TurnKit::Background.perform(run.id)
    child_id = run.child_turn_records.first.fetch("id")
    before = run.control_state
    TurnKit.authorization_policy = ->(action, **resources) do
      !%i[pause steer resume].include?(action) || resources[:turn].id != child_id
    end
    assert_raises(TurnKit::AuthorizationError) { run.pause!(descendants: :cascade) }
    assert_raises(TurnKit::AuthorizationError) { run.steer!("denied", key: "denied", descendants: :cascade) }
    assert run.reload.waiting?
    assert TurnKit.load_turn(child_id).pending?
    assert_equal before, run.control_state
  end
end
