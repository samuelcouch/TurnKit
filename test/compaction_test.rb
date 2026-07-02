# frozen_string_literal: true

require_relative "test_helper"

class CompactionTest < Minitest::Test
  def test_manual_compaction_appends_summary_and_retains_original_messages
    client = FakeClient.new(TurnKit::Result.new(text: "## Active Task\n- continue"))
    agent = TurnKit::Agent.new(
      name: "helper",
      client: client,
      compaction: { head_messages: 1, tail_messages: 1, tail_tokens: 10_000 }
    )
    conversation = agent.conversation
    6.times { |i| conversation.say("message #{i}") }

    summary = conversation.compact!(focus: "message 2")

    assert summary.context_summary?
    assert_equal 7, conversation.messages.length
    assert_equal "context_summary", conversation.messages.last.kind
    assert_equal false, summary.metadata.fetch("compaction").fetch("auto")
    assert_equal "message 2", summary.metadata.fetch("compaction").fetch("focus")
    assert_includes client.calls.first.fetch(:instructions), "anchored context summarization"
    assert_empty client.calls.first.fetch(:tools)
    assert_includes client.calls.first.fetch(:messages).last.fetch(:content), "Focus topic: \"message 2\""
  end
  def test_compaction_projection_inserts_summary_at_replaced_range
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    conversation = agent.conversation
    first = conversation.say("first")
    second = conversation.say("second")
    third = conversation.say("third")
    fourth = conversation.say("fourth")
    summary = conversation.append_message(
      role: "assistant",
      kind: "context_summary",
      text: "## Active Task\n- summarized",
      metadata: { "compaction" => { "replaces_from_sequence" => second.sequence, "replaces_through_sequence" => third.sequence } }
    )

    projected = TurnKit::Compaction.project(conversation.messages)

    assert_equal [ first.id, summary.id, fourth.id ], projected.map(&:id)
    model_messages = TurnKit::MessageProjection.for(projected)
    assert_equal "What did we do so far?", model_messages[1].fetch(:content)
    assert_includes model_messages[2].fetch(:content), "[CONTEXT COMPACTION — REFERENCE ONLY]"
    assert_includes model_messages[2].fetch(:content), "## Active Task"
  end
  def test_newer_compaction_summary_replaces_older_summary
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    conversation = agent.conversation
    5.times { |i| conversation.say("message #{i}") }
    old_summary = conversation.append_message(
      role: "assistant",
      kind: "context_summary",
      text: "old summary",
      metadata: { "compaction" => { "replaces_from_sequence" => 2, "replaces_through_sequence" => 3 } }
    )
    new_summary = conversation.append_message(
      role: "assistant",
      kind: "context_summary",
      text: "new summary",
      metadata: { "compaction" => { "replaces_from_sequence" => 2, "replaces_through_sequence" => old_summary.sequence } }
    )

    projected = TurnKit::Compaction.project(conversation.messages)

    assert_includes projected.map(&:id), new_summary.id
    refute_includes projected.map(&:id), old_summary.id
  end
  def test_auto_compaction_runs_before_main_model_call
    client = FakeClient.new(
      TurnKit::Result.new(text: "## Active Task\n- compacted", usage: TurnKit::Usage.new(input_tokens: 2)),
      TurnKit::Result.new(text: "done", usage: TurnKit::Usage.new(output_tokens: 3))
    )
    agent = TurnKit::Agent.new(
      name: "helper",
      client: client,
      compaction: { context_limit: 120, reserved_tokens: 0, threshold: 0.2, head_messages: 1, tail_messages: 1, tail_tokens: 10_000 }
    )
    conversation = agent.conversation
    6.times { |i| conversation.say("long message #{i} #{"x" * 40}") }

    turn = conversation.ask("continue")

    assert turn.completed?
    assert_equal 2, client.calls.length
    assert_equal true, client.calls.first.fetch(:metadata).fetch(:compaction)
    refute client.calls.last.fetch(:metadata).key?(:compaction)
    assert conversation.messages.any?(&:context_summary?)
    assert_includes client.calls.last.fetch(:messages).map { |message| message.fetch(:content) }, "What did we do so far?"
    assert_equal 5, turn.usage.total_tokens
  end
  def test_compaction_model_defaults_to_current_turn_model_and_can_be_overridden
    client = FakeClient.new(
      TurnKit::Result.new(text: "## Active Task\n- compacted"),
      TurnKit::Result.new(text: "done"),
      TurnKit::Result.new(text: "## Active Task\n- compacted again"),
      TurnKit::Result.new(text: "done again")
    )
    agent = TurnKit::Agent.new(
      name: "helper",
      model: "agent-model",
      client: client,
      compaction: { context_limit: 80, reserved_tokens: 0, threshold: 0.1, tail_messages: 1, tail_tokens: 10_000 }
    )
    conversation = agent.conversation(model: "conversation-model")
    4.times { |i| conversation.say("long #{i} #{"x" * 80}") }

    conversation.ask("continue", model: "turn-model")

    assert_equal "turn-model", client.calls.first.fetch(:model)

    agent = TurnKit::Agent.new(
      name: "helper",
      model: "agent-model",
      client: client,
      compaction: { model: "summary-model", context_limit: 80, reserved_tokens: 0, threshold: 0.1, tail_messages: 1, tail_tokens: 10_000 }
    )
    conversation = agent.conversation(model: "conversation-model")
    4.times { |i| conversation.say("long #{i} #{"x" * 80}") }

    conversation.ask("continue", model: "turn-model")

    assert_equal "summary-model", client.calls[2].fetch(:model)
  end
  def test_compaction_can_be_disabled_globally_and_per_turn
    TurnKit.compaction = false
    client = FakeClient.new(TurnKit::Result.new(text: "done"))
    agent = TurnKit::Agent.new(name: "helper", client: client, compaction: { context_limit: 50, reserved_tokens: 0, threshold: 0.1 })
    conversation = agent.conversation
    4.times { |i| conversation.say("long #{i} #{"x" * 100}") }

    conversation.ask("continue")

    assert_equal 1, client.calls.length
    refute conversation.messages.any?(&:context_summary?)

    TurnKit.compaction = true
    client = FakeClient.new(TurnKit::Result.new(text: "done"))
    agent = TurnKit::Agent.new(name: "helper", client: client, compaction: { context_limit: 50, reserved_tokens: 0, threshold: 0.1 })
    conversation = agent.conversation
    4.times { |i| conversation.say("long #{i} #{"x" * 100}") }

    conversation.ask("continue", compact: false)

    assert_equal 1, client.calls.length
    refute conversation.messages.any?(&:context_summary?)
  end
  def test_manual_compaction_failure_raises
    client = FakeClient.new(TurnKit::Result.new(text: ""))
    agent = TurnKit::Agent.new(name: "helper", client: client, compaction: { head_messages: 1, tail_messages: 1 })
    conversation = agent.conversation
    5.times { |i| conversation.say("message #{i}") }

    error = assert_raises(TurnKit::CompactionError) do
      conversation.compact!
    end

    assert_includes error.message, "empty summary"
  end
end
