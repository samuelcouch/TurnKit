# frozen_string_literal: true

module TurnKit
  class Store
    def atomic(_conversation_id, &) = raise(NotImplementedError)
    def atomic_graph(&) = atomic(nil, &)

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
    # Public inventory. Maintenance uses the explicitly bounded active scope.
    def list_submitted_turns(limit: nil) = raise(NotImplementedError)
    def list_actionable_turns(limit:) = raise(NotImplementedError)
    def list_stale_inline_turns(before:, limit:) = raise(NotImplementedError)

    # Stores may optimize these continuation queries without loading history.
    def busy_conversation?(id, include_pending: true)
      list_turns(conversation_id: id).any? { |row| %w[running waiting].include?(row["status"]) || (include_pending && row["submitted_at"] && row["status"] == "pending") }
    end

    def next_delivery_trigger(id)
      consumed = list_turns(conversation_id: id).reject { |row| row["status"] == "pending" && !row["submitted_at"] }.map { |row| row["context_message_sequence"] }.max.to_i
      list_messages(id).select { |row| row.dig("metadata", "delivery_id") && row["sequence"] > consumed }.last
    end

    def create_delivery(_attributes) = raise(NotImplementedError)
    def load_delivery(_id) = raise(NotImplementedError)
    def update_delivery(_id, _attributes) = raise(NotImplementedError)
    def list_deliveries(source_conversation_id: nil, destination_conversation_id: nil, pending: false, limit: nil) = raise(NotImplementedError)

    def create_wait(turn_id:, target_turn_id:) = raise(NotImplementedError)
    def list_waits(turn_id: nil, target_turn_id: nil) = raise(NotImplementedError)

    def create_tool_execution(_attributes) = raise(NotImplementedError)
    def load_tool_execution(_id) = raise(NotImplementedError)
    # claim_tool_execution mirrors claim_turn: an atomic compare-and-set on
    # status, so a tool result recorded by a live worker and a reconciler
    # marking the execution interrupted cannot overwrite each other.
    def claim_tool_execution(_id, from: "running", to: "completed", **_attributes) = raise(NotImplementedError)
    def list_tool_executions(turn_id:) = raise(NotImplementedError)

    # Inline abandoned work is fenced and left stale for application-directed
    # continuation. Submitted work is resumed by Background.reconcile instead.
    def reconcile_stale_turns(before:)
      list_stale_inline_turns(before: before, limit: TurnKit.maintenance_batch_size).filter_map do |record|
        atomic(Background.root_conversation(self, record)) do
          current = load_turn(record.fetch("id"))
          anchor = current["heartbeat_at"] || current["started_at"] || current["created_at"]
          next if current["submitted_at"] || !%w[pending running].include?(current["status"]) || anchor >= before

          update_turn(current.fetch("id"), status: "stale", claim_token: nil, completed_at: Clock.now)
        end
      end
    end
  end
end
