# frozen_string_literal: true

module TurnKit
  class Store
    def create_conversation(_attributes) = raise(NotImplementedError)
    def load_conversation(_id) = raise(NotImplementedError)

    def next_message_sequence(_conversation_id) = raise(NotImplementedError)
    def append_message(_attributes) = raise(NotImplementedError)
    def list_messages(_conversation_id, through_sequence: nil, turn_id: nil) = raise(NotImplementedError)

    def create_turn(_attributes) = raise(NotImplementedError)
    def load_turn(_id) = raise(NotImplementedError)
    def update_turn(_id, _attributes) = raise(NotImplementedError)
    # claim_turn is the concurrency-safety point: it must atomically
    # compare-and-set status from `from` to `to` (returning nil when the turn
    # is not in `from`), so concurrent workers cannot both claim a turn.
    def claim_turn(_id, from: "pending", to: "running", **_attributes) = raise(NotImplementedError)
    def list_turns(root_turn_id: nil, conversation_id: nil, agent_name: nil) = raise(NotImplementedError)

    def create_tool_execution(_attributes) = raise(NotImplementedError)
    def load_tool_execution(_id) = raise(NotImplementedError)
    # claim_tool_execution mirrors claim_turn: an atomic compare-and-set on
    # status, so a tool result recorded by a live worker and a reconciler
    # marking the execution interrupted cannot overwrite each other.
    def claim_tool_execution(_id, from: "running", to: "completed", **_attributes) = raise(NotImplementedError)
    def list_tool_executions(turn_id:) = raise(NotImplementedError)

    # reconcile_stale_turns is the other concurrency-safety point: it must
    # atomically transition each pending/running turn whose stale anchor
    # (heartbeat_at, else started_at, else created_at) is older than `before`
    # to `stale`, rechecking both predicates at write time so a concurrently
    # claimed, heartbeated, or completed turn is never overwritten. Returns
    # the reconciled turn records. Descendant turns of a dead process stop
    # heartbeating too and are reconciled by the same predicate, so no
    # explicit subtree cascade is needed.
    def reconcile_stale_turns(before:) = []
  end
end
