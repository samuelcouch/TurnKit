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
end
