# frozen_string_literal: true

require_relative "test_helper"

class ConversationTest < Minitest::Test
  def test_pending_turn_can_preview_model_request_without_calling_model
    client = FakeClient.new(TurnKit::Result.new(text: "unused"))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", instructions: "Be brief.", tools: [ StatusTool ], client: client)
    turn = agent.conversation.ask("Hi", async: true)

    request = turn.preview

    assert_equal "model-a", request.model
    assert_equal [ "status_tool" ], request.tool_names
    assert_includes request.instructions, "Be brief."
    assert_equal [ :user ], request.messages.map { |message| message.fetch(:role) }
    assert_operator request.report.fetch("chars"), :>, 0
    assert_empty client.calls
  end
  def test_lifecycle_events_are_emitted
    events = []
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new(TurnKit::Result.new(text: "hello")), on_event: ->(event) { events << event })

    turn = agent.conversation.ask("Hi")

    assert turn.completed?
    assert_includes events.map(&:type), "turn.started"
    assert_includes events.map(&:type), "model.requested"
    assert_includes events.map(&:type), "model.completed"
    assert_includes events.map(&:type), "turn.completed"
    assert events.all? { |event| event.turn_id == turn.id }
    requested = events.find { |event| event.type == "model.requested" }
    completed = events.find { |event| event.type == "model.completed" }
    assert_operator requested.payload.fetch(:prompt).fetch("chars"), :>, 0
    assert_equal 1, requested.payload.fetch(:message_count)
    assert_equal 0, completed.payload.fetch(:usage).fetch("total_tokens")
  end
  def test_turn_thinking_overrides_agent_thinking
    client = FakeClient.new(TurnKit::Result.new(text: "hello"))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", thinking: { budget: 4_000 }, client: client)

    turn = agent.conversation.ask("Hi", thinking: { effort: :high })

    assert_equal({ effort: :high }, turn.thinking)
    assert_equal({ effort: :high }, client.calls.first.fetch(:thinking))
  end
  def test_turn_thinking_can_disable_agent_thinking
    client = FakeClient.new(TurnKit::Result.new(text: "hello"))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", thinking: { budget: 4_000 }, client: client)

    turn = agent.conversation.ask("Hi", thinking: nil)

    assert_nil turn.thinking
    assert_nil client.calls.first.fetch(:thinking)
    assert_nil TurnKit.store.load_turn(turn.id).fetch("options").fetch("thinking")
  end
  def test_concurrent_turns_use_start_snapshot
    client = FakeClient.new(TurnKit::Result.new(text: "A"), TurnKit::Result.new(text: "B"))
    conversation = TurnKit::Agent.new(name: "helper", client: client).conversation

    conversation.say("first")
    turn_a = conversation.ask("a", async: true)
    conversation.say("between")
    turn_b = conversation.ask("b", async: true)

    turn_a.run!
    turn_b.run!

    first_call_messages = client.calls.first.fetch(:messages).map { |message| message.fetch(:content) }
    second_call_messages = client.calls.last.fetch(:messages).map { |message| message.fetch(:content) }

    assert_includes first_call_messages, "first"
    assert_includes first_call_messages, "a"
    refute_includes first_call_messages, "between"
    refute_includes first_call_messages, "b"

    assert_includes second_call_messages, "between"
    assert_includes second_call_messages, "b"
    refute_includes second_call_messages, "A"
  end
  def test_reconcile_stale_marks_old_running_turns_stale
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)
    TurnKit.store.update_turn(turn.id, "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 1))

    TurnKit.reconcile_stale!(before: Time.utc(2000, 1, 2))

    assert_equal "stale", TurnKit.store.load_turn(turn.id).fetch("status")
  end
  def test_content_only_messages_extract_text
    conversation = TurnKit::Agent.new(name: "helper", client: FakeClient.new).conversation

    message = conversation.append_message(
      role: "user",
      kind: "text",
      content: [ { "type" => "text", "text" => "from content" } ]
    )

    assert_equal "from content", message.text
  end
  def test_message_parts_round_trip_and_project_thinking_before_tool_calls
    agent = TurnKit::Agent.new(name: "worker", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    conversation = agent.conversation
    message = conversation.append_message(
      role: "assistant",
      kind: "tool_call",
      content: [
        { "type" => "text", "text" => "visible" },
        { "type" => "thinking", "text" => "hidden reasoning", "signature" => "sig" },
        { "type" => "tool_call", "id" => "call_1", "name" => "status_tool", "arguments" => { "id" => "st_1" } }
      ]
    )

    stored = TurnKit::Message.new(TurnKit.store.list_messages(conversation.id).last)
    projected = TurnKit::MessageProjection.for([ stored ]).first

    assert_equal message.content, stored.content
    assert_equal "visible", stored.text
    assert_match(/\Ahidden reasoning\nvisible\z/, projected.fetch(:content))
    assert_equal "call_1", projected.fetch(:tool_calls).first.fetch("id")
  end
end
