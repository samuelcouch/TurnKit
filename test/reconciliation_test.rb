# frozen_string_literal: true

require_relative "test_helper"

class SelfInterruptingTool < TurnKit::Tool
  tool_name "self_interrupting"

  def call(context:)
    TurnKit.store.claim_tool_execution(context.execution.id, from: "running", to: "interrupted", completed_at: TurnKit::Clock.now)
    { "ok" => true }
  end
end

class FalselyReconciledTool < TurnKit::Tool
  tool_name "falsely_reconciled"

  def call(context:)
    TurnKit.reconcile_stale!(before: TurnKit::Clock.now + 60)
    { "ok" => true }
  end
end

class ReconciliationTest < Minitest::Test
  def test_reconcile_interrupts_executions_and_repairs_transcript
    store = TurnKit.store
    events = []
    TurnKit.on_event = ->(event) { events << event }

    conversation = store.create_conversation("agent_name" => "helper")
    turn = store.create_turn("conversation_id" => conversation.fetch("id"), "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 1))
    store.append_message(
      "conversation_id" => conversation.fetch("id"), "turn_id" => turn.fetch("id"), "role" => "assistant", "kind" => "tool_call",
      "content" => [
        { "type" => "tool_call", "id" => "call_1", "name" => "search", "arguments" => {} },
        { "type" => "tool_call", "id" => "call_2", "name" => "publish", "arguments" => {} }
      ]
    )
    execution = store.create_tool_execution("turn_id" => turn.fetch("id"), "tool_call_id" => "call_1", "tool_name" => "search", "status" => "running", "started_at" => Time.utc(2000, 1, 1))

    reconciled = TurnKit.reconcile_stale!(before: Time.utc(2000, 1, 2))

    assert_equal [ turn.fetch("id") ], reconciled.map { |record| record.fetch("id") }
    assert_equal "stale", store.load_turn(turn.fetch("id")).fetch("status")

    interrupted = store.load_tool_execution(execution.fetch("id"))
    assert_equal "interrupted", interrupted.fetch("status")
    assert interrupted.fetch("completed_at")
    assert_includes interrupted.fetch("error").fetch("message"), "interrupted"

    results = store.list_messages(conversation.fetch("id")).select { |message| message["kind"] == "tool_result" }
    assert_equal %w[call_1 call_2], results.flat_map { |message| message["content"].map { |part| part.fetch("tool_call_id") } }.sort
    assert(results.all? { |message| message["content"].first.fetch("error") })
    assert_equal execution.fetch("id"), results.find { |message| message["content"].first.fetch("tool_call_id") == "call_1" }.fetch("tool_execution_id")
    assert_nil results.find { |message| message["content"].first.fetch("tool_call_id") == "call_2" }.fetch("tool_execution_id")

    assert_equal %w[message.created message.created tool_call.interrupted turn.stale], events.map(&:type).sort
  ensure
    TurnKit.on_event = nil
  end
  def test_reconciled_transcript_projects_a_result_for_every_tool_call
    store = TurnKit.store
    conversation = store.create_conversation("agent_name" => "helper")
    turn = store.create_turn("conversation_id" => conversation.fetch("id"), "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 1))
    store.append_message(
      "conversation_id" => conversation.fetch("id"), "turn_id" => turn.fetch("id"), "role" => "assistant", "kind" => "tool_call",
      "content" => [ { "type" => "tool_call", "id" => "call_1", "name" => "search", "arguments" => {} } ]
    )

    TurnKit.reconcile_stale!(before: Time.utc(2000, 1, 2))

    messages = store.list_messages(conversation.fetch("id")).map { |attrs| TurnKit::Message.new(attrs) }
    projected = TurnKit::MessageProjection.for(messages)
    call_ids = projected.filter_map { |message| message[:tool_calls] }.flatten.map { |call| call.fetch("id") }
    result_ids = projected.select { |message| message[:role] == :tool }.map { |message| message[:tool_call_id] }
    assert_equal call_ids.sort, result_ids.sort
  end
  def test_reconcile_does_not_duplicate_results_for_resolved_tool_calls
    store = TurnKit.store
    conversation = store.create_conversation("agent_name" => "helper")
    turn = store.create_turn("conversation_id" => conversation.fetch("id"), "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 1))
    store.append_message(
      "conversation_id" => conversation.fetch("id"), "turn_id" => turn.fetch("id"), "role" => "assistant", "kind" => "tool_call",
      "content" => [ { "type" => "tool_call", "id" => "call_1", "name" => "search", "arguments" => {} } ]
    )
    store.append_message(
      "conversation_id" => conversation.fetch("id"), "turn_id" => turn.fetch("id"), "role" => "tool", "kind" => "tool_result",
      "content" => [ { "type" => "tool_result", "tool_call_id" => "call_1", "text" => "{}", "error" => false } ]
    )

    TurnKit.reconcile_stale!(before: Time.utc(2000, 1, 2))

    results = store.list_messages(conversation.fetch("id")).select { |message| message["kind"] == "tool_result" }
    assert_equal 1, results.length
  end
  # `stale` is provisional: reconciliation never spawns a successor turn, so a
  # still-live worker keeps commit authority and finishes its turn normally —
  # while the interrupted tool execution and its synthetic result stay
  # authoritative (first-commit-wins at the tool level).
  def test_false_stale_is_overwritten_when_the_original_worker_finishes
    events = []
    TurnKit.on_event = ->(event) { events << event }
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "falsely_reconciled", arguments: {}) ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ FalselyReconciledTool ])

    turn = agent.conversation.ask("go")

    assert turn.completed?
    execution = turn.tool_executions.first
    assert execution.interrupted?
    assert_nil execution.result

    results = TurnKit.store.list_messages(turn.conversation.id).select { |message| message["kind"] == "tool_result" }
    assert_equal 1, results.length
    assert results.first["content"].first.fetch("error")

    types = events.map(&:type)
    assert_operator types.index("turn.stale"), :<, types.index("turn.completed")
  ensure
    TurnKit.on_event = nil
  end
  def test_late_tool_completion_does_not_overwrite_interrupted_execution
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "self_interrupting", arguments: {}) ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ SelfInterruptingTool ])

    turn = agent.conversation.ask("go")

    execution = turn.tool_executions.first
    assert execution.interrupted?
    assert_nil execution.result
    results = TurnKit.store.list_messages(turn.conversation.id).select { |message| message["kind"] == "tool_result" }
    assert_equal [], results
  end
end
