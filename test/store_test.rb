# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  def test_store_rejects_unknown_update_attributes
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)

    error = assert_raises(ArgumentError) do
      TurnKit.store.update_turn(turn.id, "bogus" => true)
    end
    assert_includes error.message, "unknown turn update attributes"
  end
  def test_store_rejects_unknown_statuses
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)

    error = assert_raises(ArgumentError) do
      TurnKit.store.update_turn(turn.id, "status" => "lost")
    end
    assert_includes error.message, "unknown turn status"
  end
  def test_store_claim_turn_is_compare_and_swap
    agent = TurnKit::Agent.new(name: "worker", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    run = agent.run("Later", async: true)

    claimed = TurnKit.store.claim_turn(run.id, started_at: Time.utc(2026, 1, 1))
    second = TurnKit.store.claim_turn(run.id, started_at: Time.utc(2026, 1, 2))

    assert_equal "running", claimed.fetch("status")
    assert_nil second
    assert_equal Time.utc(2026, 1, 1), TurnKit.store.load_turn(run.id).fetch("started_at")
  end
  def test_store_claim_tool_execution_is_compare_and_swap
    store = TurnKit.store
    execution = store.create_tool_execution("turn_id" => "t_1", "tool_call_id" => "call_1", "tool_name" => "search", "status" => "running")

    interrupted = store.claim_tool_execution(execution.fetch("id"), from: "running", to: "interrupted", completed_at: Time.utc(2026, 1, 1))
    late = store.claim_tool_execution(execution.fetch("id"), from: "running", to: "completed", result: { "ok" => true })

    assert_equal "interrupted", interrupted.fetch("status")
    assert_nil late
    assert_equal "interrupted", store.load_tool_execution(execution.fetch("id")).fetch("status")
  end
  def test_store_reconcile_stale_turns_only_transitions_eligible_turns
    store = TurnKit.store
    old = Time.utc(2000, 1, 1)
    store.create_turn("id" => "t_old_running", "conversation_id" => "c_1", "status" => "running", "heartbeat_at" => old)
    store.create_turn("id" => "t_old_pending", "conversation_id" => "c_1", "status" => "pending", "created_at" => old)
    store.create_turn("id" => "t_fresh", "conversation_id" => "c_1", "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 3))
    store.create_turn("id" => "t_done", "conversation_id" => "c_1", "status" => "completed", "heartbeat_at" => old)

    reconciled = store.reconcile_stale_turns(before: Time.utc(2000, 1, 2))

    assert_equal %w[t_old_pending t_old_running], reconciled.map { |turn| turn.fetch("id") }.sort
    assert reconciled.all? { |turn| turn.fetch("status") == "stale" && turn.fetch("completed_at") }
    assert_equal "running", store.load_turn("t_fresh").fetch("status")
    assert_equal "completed", store.load_turn("t_done").fetch("status")
  end
end
