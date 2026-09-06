# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class BackgroundTest < Minitest::Test
  class BlockingClient < FakeClient
    attr_reader :entered, :release

    def initialize(text = "finished")
      super(TurnKit::Result.new(text: text))
      @entered, @release = Queue.new, Queue.new
    end

    def chat(**options)
      @entered << true
      @release.pop
      super
    end
  end

  class CountingTool < TurnKit::Tool
    tool_name "counting"
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def call(context:)
      @calls += 1
      { "count" => calls }
    end
  end

  def setup
    super
    TurnKit.compaction = false
    TurnKit.on_event = nil
    TurnKit.agents.clear
    @jobs = Queue.new
    TurnKit.job_dispatcher = ->(id) { @jobs << id }
  end

  def teardown
    TurnKit.job_dispatcher = nil
    TurnKit.on_event = nil
    TurnKit.agents.clear
    super
  end

  def test_pending_preview_is_not_submitted_and_missed_enqueue_is_repaired
    client = FakeClient.new(TurnKit::Result.new(text: "done"))
    agent = register("worker", client: client)
    preview = agent.run("preview", async: true)
    work = agent.run("work", async: true)
    TurnKit.job_dispatcher = ->(_id) { raise IOError, "queue unavailable" }
    assert_raises(IOError) { work.perform_later }
    assert_empty client.calls
    refute_nil TurnKit.store.load_turn(work.id)["submitted_at"]
    TurnKit.job_dispatcher = ->(id) { @jobs << id }
    TurnKit::Background.reconcile
    drain_jobs
    assert work.reload.completed?
    assert preview.reload.pending?
    assert_nil TurnKit.store.load_turn(preview.id)["submitted_at"]
    assert_equal 1, client.calls.length
  end

  def test_duplicate_job_does_not_repeat_a_completed_turn
    client = FakeClient.new(TurnKit::Result.new(text: "done"))
    run = register("worker", client: client).run("work", async: true).perform_later
    2.times { TurnKit::Background.perform(run.id) }
    assert_equal 1, client.calls.length
    assert run.reload.completed?
  end

  def test_provider_rejection_fails_durably_without_reconciliation_retries
    require "ruby_llm"
    client = TurnKit::Adapters::RubyLLM.new
    client.define_singleton_method(:validate!) { |**| true }
    original_chat = RubyLLM.method(:chat)
    attempts = 0
    rejected = ->(**) { attempts += 1; raise RubyLLM::BadRequestError, "unsupported tool protocol" }
    RubyLLM.define_singleton_method(:chat, rejected)
    run = register("worker", client: client).run("work", async: true).perform_later
    drain_jobs
    assert run.reload.failed?
    assert_equal "TurnKit::ModelError", TurnKit.store.load_turn(run.id).dig("error", "class")
    TurnKit::Background.reconcile
    drain_jobs
    TurnKit::Background.perform(run.id)
    assert_equal 1, attempts
    assert run.reload.failed?
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat) if original_chat
  end

  def test_reconstructed_conversation_retains_subject_prompt_data
    client = FakeClient.new(TurnKit::Result.new(text: "done"))
    run = register("worker", client: client).run("work", subject: PromptSubject.new, async: true).perform_later
    drain_jobs
    assert_includes client.calls.first.fetch(:instructions), "Subject facts."
    assert_equal "Subject facts.", TurnKit.load_conversation(run.turn.conversation.id).subject_prompt
  end

  def test_model_response_is_reused_after_worker_dies_before_dispatch
    tool = CountingTool.new
    client = FakeClient.new(calls(["call", "counting", {}]), TurnKit::Result.new(text: "done"))
    fired = false
    agent = register("worker", client: client, tools: [tool], on_event: ->(event) {
      if event.type == "model.completed" && !fired
        fired = true
        raise IOError, "lost worker"
      end
    })
    run = agent.run("work", async: true).perform_later
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    assert_equal 0, tool.calls
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, tool.calls
    assert_equal 2, client.calls.length
  end

  def test_parallel_children_share_atomic_tool_budget
    tool = CountingTool.new
    first = register("first", tools: [tool], client: FakeClient.new(calls(["a", "counting", {}]), TurnKit::Result.new(text: "a")))
    second = register("second", tools: [tool], client: FakeClient.new(calls(["b", "counting", {}]), TurnKit::Result.new(text: "b")))
    client = FakeClient.new(calls(["first", "first", { task: "a" }], ["second", "second", { task: "b" }]), TurnKit::Result.new(text: "joined"))
    parent = register("parent", client: client, sub_agents: [first, second], max_tool_executions: 3).run("work", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    threads = parent.child_turn_records.map { |child| Thread.new { TurnKit::Background.perform(child.fetch("id")) } }
    threads.each(&:value)
    drain_jobs
    assert parent.reload.completed?
    assert_equal 1, tool.calls
    assert_equal 1, parent.failed_turn_records.length
    assert_includes parent.failed_turn_records.first.dig("error", "message"), "maximum tool executions"
  end

  def test_shared_iteration_limit_is_reserved_before_parallel_model_calls
    first, second = register("first"), register("second")
    client = FakeClient.new(calls(["first", "first", { task: "a" }], ["second", "second", { task: "b" }]))
    parent = register("parent", client: client, sub_agents: [first, second], max_iterations: 2).run("work", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    threads = parent.child_turn_records.map { |child| Thread.new { TurnKit::Background.perform(child.fetch("id")) } }
    threads.each(&:value)
    drain_jobs
    assert_equal 2, parent.turn_records.sum { |record| TurnKit::Turn.iterations_for(record) }
    assert_equal 1, first.client.calls.length + second.client.calls.length
    assert parent.reload.failed?
  end

  def test_waiting_does_not_expire_as_a_dead_worker
    child = register("child").run("child", async: true).perform_later
    parent = register("parent").run("parent", async: true).perform_later.wait_for(child)
    TurnKit.store.update_turn(parent.id, heartbeat_at: Time.utc(2000, 1, 1))
    TurnKit::Background.reconcile
    assert parent.reload.waiting?
  end

  def test_waiting_respects_root_deadline
    child = register("child").run("child", async: true).perform_later
    parent = register("parent").run("parent", async: true).wait_for(child).perform_later
    TurnKit.store.update_turn(parent.id, submitted_at: Time.utc(2000, 1, 1))
    TurnKit::Background.reconcile
    TurnKit::Background.perform(parent.id)
    assert parent.reload.failed?
    assert_includes parent.error.fetch("message"), "timed out"
  end

  def test_invalid_subagent_result_does_not_overtake_earlier_child
    child = register("child")
    client = FakeClient.new(calls(["first", "child", { task: "valid" }], ["second", "child", { task: 123 }]), TurnKit::Result.new(text: "done"))
    parent = register("parent", client: client, sub_agents: [child]).run("work", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    assert parent.reload.waiting?
    assert_empty parent.turn.conversation.messages.select { |message| message.kind == "tool_result" }
    drain_jobs
    results = parent.turn.conversation.messages.select { |message| message.kind == "tool_result" }
    assert_equal %w[first second], results.map { |message| message.content.first.fetch("tool_call_id") }
    assert results.last.content.first.fetch("error")
  end

  def test_recovery_finishes_partially_dispatched_subagent_group
    child = register("child")
    client = FakeClient.new(calls(["first", "child", { task: "a" }], ["second", "child", { task: "b" }]), TurnKit::Result.new(text: "done"))
    parent = register("parent", client: client, sub_agents: [child]).run("work", async: true).perform_later
    TurnKit.job_dispatcher = ->(_id) { raise IOError, "queue unavailable after child commit" }
    assert_raises(IOError) { TurnKit::Background.perform(parent.id) }
    assert_equal 1, parent.child_turn_records.length
    expire(parent)
    TurnKit.job_dispatcher = ->(id) { @jobs << id }
    TurnKit::Background.reconcile
    drain_jobs
    assert parent.reload.completed?
    assert_equal 2, parent.child_turn_records.length
    assert_equal 2, client.calls.length
  end

  def test_parallel_children_release_parent_and_return_results_in_call_order
    a, b = BlockingClient.new("a"), BlockingClient.new("b")
    first, second = register("first", client: a), register("second", client: b)
    parent_client = FakeClient.new(calls(["a", "first", { task: "a" }], ["b", "second", { task: "b" }]), TurnKit::Result.new(text: "joined"))
    parent = register("parent", client: parent_client, sub_agents: [first, second]).run("delegate", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    assert parent.reload.waiting?
    children = parent.child_turn_records
    assert_equal 2, children.length
    threads = children.map { |child| Thread.new { TurnKit::Background.perform(child.fetch("id")) } }
    Timeout.timeout(5) { a.entered.pop; b.entered.pop }
    assert_equal 1, parent_client.calls.length
    b.release << true
    threads[1].value
    assert parent.reload.waiting?
    a.release << true
    threads[0].value
    drain_jobs
    assert parent.reload.completed?
    assert_equal "joined", parent.output_text
    results = parent.turn.conversation.messages.select { |message| message.kind == "tool_result" }
    assert_equal %w[a b], results.map { |message| message.content.first.fetch("tool_call_id") }
    assert_equal %w[a b], results.map { |message| JSON.parse(message.content.first.fetch("text")).fetch("result") }
    assert_equal 2, parent_client.calls.length
  ensure
    a&.release&.push(true)
    b&.release&.push(true)
    threads&.each(&:join)
  end

  def test_message_to_running_conversation_is_delivered_once_and_used_next_turn
    client = BlockingClient.new
    destination = register("receiver", client: client).conversation
    source = register("sender").conversation
    turn = destination.ask("original", async: true).perform_later
    thread = Thread.new { TurnKit::Background.perform(turn.id) }
    Timeout.timeout(5) { client.entered.pop }
    delivery = source.send_message(destination, "new information", key: "one")
    duplicate = source.send_message(destination, "new information", key: "one")
    assert_equal delivery.fetch("id"), duplicate.fetch("id")
    2.times { TurnKit::Background.deliver(delivery) }
    assert_equal 1, TurnKit.store.list_turns(conversation_id: destination.id).length
    client.release << true
    thread.value
    refute_includes client.calls.first.fetch(:messages).map { |message| message[:content] }, "new information"
    client.release << true
    drain_jobs
    assert_equal 2, client.calls.length
    assert_includes client.calls.last.fetch(:messages).map { |message| message[:content] }, "new information"
    assert_equal 1, source.outbox.length
    assert_equal 1, destination.inbox.length
    assert destination.inbox.first["delivered_at"]
  ensure
    client&.release&.push(true)
    thread&.join
  end

  def test_callback_is_durable_even_if_completion_event_crashes
    destination = register("receiver").conversation
    agent = register("child", on_event: ->(event) { raise IOError, "worker lost" if event.type == "turn.completed" })
    run = agent.run("work", async: true).perform_later(callback: destination)
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    assert run.reload.completed?
    assert_equal 1, TurnKit.store.list_deliveries(pending: true).length
    TurnKit::Background.reconcile
    drain_jobs
    assert_equal 1, destination.inbox.length
    payload = JSON.parse(destination.messages.first.text)
    assert_equal run.id, payload.fetch("turn_id")
  end

  def test_resume_reuses_recorded_model_response_and_tool_result
    tool = CountingTool.new
    client = FakeClient.new(calls(["call", "counting", {}]), TurnKit::Result.new(text: "done"))
    fired = false
    agent = register("worker", client: client, tools: [tool], on_event: ->(event) {
      if event.type == "tool_call.completed" && !fired
        fired = true
        raise IOError, "worker died after tool commit"
      end
    })
    run = agent.run("work", async: true).perform_later
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    assert_equal 1, tool.calls
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, tool.calls
    assert_equal 2, client.calls.length
    assert_equal 1, run.turn.conversation.messages.count { |message| message.kind == "tool_result" }
  end

  def test_interrupted_external_tool_is_not_replayed
    tool = CountingTool.new
    def tool.call(context:)
      super
      raise IOError, "worker died during external effect"
    end
    client = FakeClient.new(calls(["call", "counting", {}]), TurnKit::Result.new(text: "outcome unknown"))
    run = register("worker", client: client, tools: [tool]).run("work", async: true).perform_later
    assert_raises(IOError) { TurnKit::Background.perform(run.id) }
    expire(run)
    TurnKit::Background.reconcile
    drain_jobs
    assert run.reload.completed?
    assert_equal 1, tool.calls
    execution = run.tool_executions.first
    assert execution.interrupted?
    result = run.turn.conversation.messages.find { |message| message.kind == "tool_result" }
    assert_includes result.content.first.fetch("text"), "unknown"
  end

  def test_late_model_response_cannot_write_after_claim_revoked
    client = BlockingClient.new("late")
    run = register("worker", client: client).run("work", async: true).perform_later
    thread = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { client.entered.pop }
    expire(run)
    TurnKit::Background.reconcile
    client.release << true
    thread.value
    assert_empty run.turn.conversation.messages.select { |message| message.role == "assistant" }
    assert run.reload.pending?
  ensure
    client&.release&.push(true)
    thread&.join
  end

  def test_heartbeat_covers_a_blocked_model_request
    TurnKit.timeout = 0.06
    client = BlockingClient.new
    run = register("worker", client: client, timeout: 10).run("work", async: true).perform_later
    thread = Thread.new { TurnKit::Background.perform(run.id) }
    Timeout.timeout(5) { client.entered.pop }
    initial = TurnKit.store.load_turn(run.id).fetch("heartbeat_at")
    Timeout.timeout(5) do
      sleep 0.005 until TurnKit.store.load_turn(run.id).fetch("heartbeat_at") > initial
    end
    TurnKit::Background.reconcile(before: initial + 0.001)
    assert_equal "running", TurnKit.store.load_turn(run.id).fetch("status")
    client.release << true
    thread.value
    assert run.reload.completed?
  ensure
    client&.release&.push(true)
    thread&.join
    TurnKit.timeout = 300
  end

  def test_wait_tool_suspends_and_resumes_without_repeating_model_request
    child = register("child").run("child", async: true).perform_later
    client = FakeClient.new(calls(["wait", "wait_for", { turn_ids: [child.id] }]), TurnKit::Result.new(text: "joined"))
    parent = register("parent", client: client, tools: [TurnKit::WaitTool]).run("wait", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    assert parent.reload.waiting?
    TurnKit::Background.perform(child.id)
    drain_jobs
    assert parent.reload.completed?
    assert_equal 2, client.calls.length
    assert_equal 1, parent.tool_executions.length
  end

  def test_explicit_wait_can_be_attached_before_execution
    child = register("child").run("child", async: true).perform_later
    client = FakeClient.new(TurnKit::Result.new(text: "joined"))
    parent = register("parent", client: client).run("parent", async: true).wait_for(child).perform_later
    assert parent.waiting?
    TurnKit::Background.perform(parent.id)
    assert parent.reload.waiting?
    drain_jobs
    assert parent.reload.completed?
    assert client.calls.first.fetch(:messages).any? { |message| message[:content].to_s.include?("wait_results") }
  end

  def test_a_completed_execution_cannot_write_again
    run = register("worker").run("work", async: true).perform_later
    loaded = TurnKit.load_turn(run.id)
    loaded.run!
    assert loaded.completed?
    assert_raises(TurnKit::LostClaim) { loaded.store.append_message("conversation_id" => loaded.conversation.id, "role" => "assistant", "kind" => "text", "text" => "late") }
  end

  def test_terminal_tool_prevents_later_subagent_launch
    child_client = FakeClient.new
    child = register("child", client: child_client)
    client = FakeClient.new(calls(["save", "save_report", { title: "t", body: "b" }], ["child", "child", { task: "unused" }]))
    parent = register("parent", client: client, tools: [SaveReport], sub_agents: [child]).run("work", async: true).perform_later
    drain_jobs
    assert parent.reload.completed?
    assert_empty parent.child_turn_records
    assert_empty child_client.calls
    assert parent.tool_executions.last.cancelled?
  end

  def test_detached_launch_returns_immediately_and_callbacks_later
    child_client = BlockingClient.new
    child = register("child", client: child_client)
    client = FakeClient.new(calls(["launch", "launch_agent", { agent_name: "child", task: "work", callback: true }]), TurnKit::Result.new(text: "continuing"), TurnKit::Result.new(text: "received"))
    parent = register("parent", client: client, sub_agents: [child], tools: [TurnKit::LaunchAgentTool]).run("launch", async: true).perform_later
    TurnKit::Background.perform(parent.id)
    assert parent.reload.completed?
    assert_equal "continuing", parent.output_text
    assert_empty child_client.calls
    child_client.release << true
    drain_jobs
    assert_equal 1, parent.turn.conversation.inbox.length
    assert_equal 3, client.calls.length
  end

  private

    def register(name, client: FakeClient.new(TurnKit::Result.new(text: "done")), **options)
      TurnKit.register(TurnKit::Agent.new(name: name, client: client, **options))
    end

    def calls(*specs)
      TurnKit::Result.new(tool_calls: specs.map { |id, name, arguments| TurnKit::ToolCall.new(id: id, name: name, arguments: arguments) })
    end

    def expire(run)
      TurnKit.store.update_turn(run.id, heartbeat_at: Time.utc(2000, 1, 1))
    end

  public
    def test_wait_rejects_transitive_cycle_atomically
      agent = register("waiter")
      runs = 3.times.map { agent.run("work", async: true).tap(&:perform_later) }
      runs[0].wait_for(runs[1])
      runs[1].wait_for(runs[2])

      error = assert_raises(TurnKit::ToolError) { runs[2].wait_for(runs[0]) }
      assert_match(/cycle/, error.message)
      assert_empty TurnKit.store.list_waits(turn_id: runs[2].id)
    end

    def test_authorization_denies_tool_before_side_effect
      tool = CountingTool.new
      agent = register("secured", tools: [tool], client: FakeClient.new(calls(["one", "counting", {}])))
      TurnKit.authorization_policy = ->(action, principal:, **) { action != :tool }

      run = agent.run("work", principal: "application-user")

      assert_equal 0, tool.calls
      assert run.tool_executions.all?(&:failed?)
    end

    def test_heartbeat_shutdown_finishes_an_in_flight_write
      TurnKit.timeout = 0.03
      entered, release, finished, body_done = Queue.new, Queue.new, Queue.new, Queue.new
      turn = register("heartbeat_shutdown").run("work", async: true).turn
      turn.define_singleton_method(:heartbeat!) do
        entered << true
        release.pop
        finished << true
      end
      worker = Thread.new { turn.send(:with_heartbeat) { entered.pop; body_done << true } }
      Timeout.timeout(5) { body_done.pop }
      # Completion waits for the in-flight heartbeat instead of killing it.
      assert_nil worker.join(0.1)
      release << true
      Timeout.timeout(5) { worker.value }
      assert_equal true, finished.pop
    ensure
      release&.push(true)
      worker&.join
      TurnKit.timeout = 300
    end

    def test_launch_policy_applies_to_inline_and_background_delegation
      TurnKit.authorization_policy = ->(action, **) { action != :launch_agent }
      [false, true].each do |background|
        child_client = FakeClient.new
        child = register("denied_child", client: child_client)
        parent = register("denied_parent", sub_agents: [child],
          client: FakeClient.new(calls(["child", "denied_child", { task: "must not launch" }])))
        run = parent.run("delegate", async: background, principal: "owner")
        if background
          run.perform_later
          TurnKit::Background.perform(run.id)
        end
        assert run.reload.completed?
        assert_empty child_client.calls
        assert_empty run.child_turn_records
        assert run.tool_executions.first.failed?
      end
    end

    def test_cancel_cascades_and_context_is_persisted
      agent = register("cancel")
      run = agent.run("work", async: true, context: { "tenant" => "acme" })
      child = agent.conversation.build_turn(parent_turn: run.turn)

      run.cancel!(descendants: :cascade)

      assert_equal({ "tenant" => "acme" }, run.turn.context)
      assert_equal "cancelled", TurnKit.store.load_turn(child.id)["status"]
    end

    def test_concurrent_opposite_waits_reject_one_edge
      agent = register("opposite")
      runs = 2.times.map { agent.run("wait", async: true).perform_later }
      ready, start = Queue.new, Queue.new
      threads = 2.times.map do |i|
        Thread.new do
          ready << true
          start.pop
          runs[i].wait_for(runs[1 - i])
          :accepted
        rescue TurnKit::ToolError => error
          error.message
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      results = Timeout.timeout(10) { threads.map(&:value) }
      assert_equal 1, results.count(:accepted)
      assert results.any? { |result| result.to_s.include?("cycle") }
      assert_equal 1, TurnKit.store.list_waits.length
    end

    def test_cancel_during_model_call_fences_result_and_wakes_buffered_input
      client = BlockingClient.new
      agent = register("blocked_cancel", client: client)
      run = agent.run("first", async: true, principal: "owner").perform_later
      worker = Thread.new { TurnKit::Background.perform(run.id) }
      Timeout.timeout(5) { client.entered.pop }
      source = register("sender").conversation
      source.send_message(run.turn.conversation.id, "later", key: "cancel-wake")
      TurnKit::Background.drain
      TurnKit.load_turn(run.id).cancel!
      client.release << true
      Timeout.timeout(5) { worker.value }
      assert run.reload.cancelled?
      assert_nil TurnKit.store.load_turn(run.id)["output_text"]
      continuation = TurnKit.store.list_turns(conversation_id: run.turn.conversation.id).find { |row| row["id"] != run.id }
      assert_equal "pending", continuation["status"]
      assert_equal "owner", continuation.dig("options", "principal")
    ensure
      client&.release&.push(true)
    end

    def test_cancelling_child_cascades_only_its_descendants
      agent = register("tree")
      root = agent.run("root", async: true)
      child = agent.conversation.build_turn(parent_turn: root.turn)
      sibling = agent.conversation.build_turn(parent_turn: root.turn)
      grandchild = agent.conversation.build_turn(parent_turn: child)
      child.cancel!(descendants: :cascade)
      assert root.reload.pending?
      assert sibling.reload.pending?
      assert child.reload.cancelled?
      assert grandchild.reload.cancelled?
    end

    def test_message_and_callback_authorization_prevents_writes
      agent = register("secure_destination")
      source, destination = agent.conversation, agent.conversation
      run = agent.run("work", async: true, principal: "owner")
      TurnKit.authorization_policy = ->(*) { false }
      assert_raises(TurnKit::AuthorizationError) { source.send_message(destination.id, "no", key: "denied") }
      assert_raises(TurnKit::AuthorizationError) { run.perform_later(callback: destination) }
      assert_empty TurnKit.store.list_deliveries
      assert_nil TurnKit.store.load_turn(run.id)["submitted_at"]
    end

    def test_revoked_callback_permission_does_not_prevent_completion
      agent = register("callback_revoke")
      destination = agent.conversation
      run = agent.run("work", async: true).perform_later(callback: destination)
      TurnKit.authorization_policy = ->(action, **) { action != :callback }
      TurnKit::Background.perform(run.id)
      assert run.reload.completed?
      assert_empty TurnKit.store.list_deliveries
      assert TurnKit.store.load_turn(run.id).dig("options", "callback_denied")
    end

    def test_loaded_skill_tools_survive_worker_reconstruction
      tool = Class.new(TurnKit::Tool) do
        tool_name "skill_read"
        def call(context:) = { "result" => "read" }
      end
      skill = TurnKit::Skill.new(key: "research", name: "Research", content: "Read carefully", tools: [tool])
      agent = register("skill_worker", available_skills: [skill],
        client: FakeClient.new(calls(["load", "load_skill", { key: "research" }])),
        on_event: ->(event) { raise IOError, "worker died" if event.type == "tool_call.completed" })
      run = agent.run("research", async: true).perform_later
      assert_raises(IOError) { TurnKit::Background.perform(run.id) }
      client = FakeClient.new(calls(["read", "skill_read", {}]), TurnKit::Result.new(text: "done"))
      register("skill_worker", available_skills: [skill], client: client)
      expire(run)
      TurnKit::Background.reconcile
      TurnKit::Background.perform(run.id)
      assert run.reload.completed?
      assert_includes client.calls.first[:tools].map(&:tool_name), "skill_read"
      assert_equal 1, run.tool_executions.count { |execution| execution.tool_name == "load_skill" }
      assert run.tool_executions.last.completed?
    end

    def test_replay_safe_effect_reuses_key_across_repeated_worker_crashes
      keys, effects = [], {}
      tool = Class.new(TurnKit::Tool) do
        tool_name "safe_effect"
        recovery :replay_safe
      end.new
      tool.define_singleton_method(:call) do |context:|
        keys << context.idempotency_key
        effects[context.idempotency_key] ||= "external-result"
        raise IOError, "died after external commit" if keys.length <= 2
        { "result" => effects.fetch(context.idempotency_key) }
      end
      client = FakeClient.new(calls(["effect", "safe_effect", {}]), TurnKit::Result.new(text: "done"))
      run = register("safe_recovery", client: client, tools: [tool]).run("work", async: true).perform_later
      2.times do
        assert_raises(IOError) { TurnKit::Background.perform(run.id) }
        expire(run)
        TurnKit::Background.reconcile
      end
      TurnKit::Background.perform(run.id)
      assert run.reload.completed?
      assert_equal 3, keys.length
      assert_equal 1, keys.uniq.length
      assert_equal 1, effects.length
      assert_equal 1, run.tool_executions.length
    end

    def test_maintenance_reaches_work_beyond_blocked_batch_and_ignores_history
      TurnKit.maintenance_batch_size = 2
      agent = register("maintenance")
      4.times { agent.run("historical", async: true).perform_later.tap { |run| TurnKit::Background.perform(run.id) } }
      conversation = agent.conversation
      blocker = conversation.ask("blocked", async: true).tap(&:perform_later)
      TurnKit.store.claim_turn(blocker.id, heartbeat_at: TurnKit::Clock.now, claim_token: "held")
      4.times { conversation.ask("queued", async: true).perform_later }
      ready = agent.run("ready", async: true).perform_later
      @jobs.pop until @jobs.empty?
      8.times { TurnKit::Background.reconcile }
      queued = []
      queued << @jobs.pop until @jobs.empty?
      assert_includes queued, ready.id
      actionable = TurnKit.store.list_actionable_turns(limit: 100)
      assert_equal 6, actionable.length
      assert actionable.none? { |row| row["status"] == "completed" }
      assert_equal 10, TurnKit.store.list_submitted_turns.length
    end

    def test_wait_policy_covers_implicit_subagent_join
      child = register("wait_child")
      parent = register("wait_parent", sub_agents: [child],
        client: FakeClient.new(calls(["child", "wait_child", { task: "work" }])))
      seen = []
      TurnKit.authorization_policy = ->(action, **) { seen << action; action != :wait }
      run = parent.run("delegate", async: true, principal: "owner").perform_later
      TurnKit::Background.perform(run.id)
      assert_includes seen, :wait
      assert_empty TurnKit.store.list_waits(turn_id: run.id)
      assert_empty run.child_turn_records
      assert run.tool_executions.first.failed?
    end

    def test_public_reconciliation_is_bounded_and_does_not_load_history
      TurnKit.maintenance_batch_size = 2
      agent = register("inline_maintenance")
      4.times { agent.run("history") }
      stale = 3.times.map { agent.run("abandoned", async: true) }
      stale.each { |run| TurnKit.store.claim_turn(run.id, started_at: Time.utc(2000, 1, 1), heartbeat_at: Time.utc(2000, 1, 1)) }
      original = TurnKit.store.method(:list_turns)
      TurnKit.store.define_singleton_method(:list_turns) do |**filters|
        raise "unbounded historical list_turns" if filters.empty?
        original.call(**filters)
      end
      before = TurnKit::Clock.now - 300
      assert_equal 2, TurnKit::Reconciliation.reconcile!(before: before).length
      assert_equal 1, TurnKit::Reconciliation.reconcile!(before: before).length
      assert_equal 0, TurnKit::Reconciliation.reconcile!(before: before).length
      assert stale.all? { |run| run.reload.stale? }
    end

    def test_wait_cycle_includes_conversation_serialization
      agent = register("serial_wait")
      a = agent.run("a", async: true).perform_later
      conversation = agent.conversation
      c = conversation.ask("c", async: true).perform_later
      b = conversation.ask("b", async: true).perform_later
      c.wait_for(a)
      assert_raises(TurnKit::ToolError) { a.wait_for(b) }
      assert_empty TurnKit.store.list_waits(turn_id: a.id)
      # A completed target no longer creates a blocking dependency.
      b.cancel!
      a.wait_for(b)
    end

    def test_delivery_key_collision_does_not_disclose_another_principals_payload
      agent = register("private_messages")
      a, b, c, d = 4.times.map { agent.conversation }
      TurnKit.authorization_policy = ->(action, principal:, **resources) {
        action == :send_message &&
          ((principal == "alice" && resources[:source_conversation] == a.id && resources[:destination_conversation] == b.id) ||
           (principal == "bob" && resources[:source_conversation] == c.id && resources[:destination_conversation] == d.id))
      }
      first = a.send_message(b, "alice confidential content", key: "request-1", principal: "alice")
      retry_result = a.send_message(b, "alice confidential content", key: "request-1", principal: "alice")
      assert_equal first["id"], retry_result["id"]
      error = assert_raises(TurnKit::ToolError) { c.send_message(d, "bob content", key: "request-1", principal: "bob") }
      refute_includes error.message, "alice confidential content"
      assert_raises(TurnKit::ToolError) { a.send_message(b, "changed content", key: "request-1", principal: "alice") }
      assert_equal 1, TurnKit.store.list_deliveries.length
    end

    def test_delivery_retries_canonicalize_json_payloads
      agent = register("delivery_json")
      source, destination = agent.conversation, agent.conversation
      attrs = { source_conversation_id: source.id, destination_conversation_id: destination.id, key: "json", payload: { text: "same" } }
      first = TurnKit.store.create_delivery(attrs)
      second = TurnKit.store.create_delivery(attrs.merge(payload: { "text" => "same" }))
      assert_equal first["id"], second["id"]
    end

    def test_cancelled_tool_cannot_append_late_message
      entered, release = Queue.new, Queue.new
      tool = Class.new(TurnKit::Tool) { tool_name "late_write" }.new
      tool.define_singleton_method(:call) do |context:|
        entered << true
        release.pop
        context.turn.conversation.say("late tool write")
      end
      run = register("late_writer", tools: [tool], client: FakeClient.new(calls(["effect", "late_write", {}])))
        .run("work", async: true).perform_later
      worker = Thread.new { TurnKit::Background.perform(run.id) }
      Timeout.timeout(5) { entered.pop }
      TurnKit.load_turn(run.id).cancel!
      release << true
      Timeout.timeout(5) { worker.value }
      assert run.reload.cancelled?
      refute run.messages.any? { |message| message.text == "late tool write" }
      assert_equal "interrupted", run.tool_executions.first.status
    ensure
      release&.push(true)
      worker&.join
    end

  private
    def drain_jobs
      100.times do
        return if @jobs.empty?
        TurnKit::Background.perform(@jobs.pop)
      end
      flunk "background queue did not settle"
    end
end
