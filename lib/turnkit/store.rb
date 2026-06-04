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
    def list_turns(root_turn_id: nil, conversation_id: nil) = raise(NotImplementedError)

    def create_tool_execution(_attributes) = raise(NotImplementedError)
    def load_tool_execution(_id) = raise(NotImplementedError)
    def update_tool_execution(_id, _attributes) = raise(NotImplementedError)
    def list_tool_executions(turn_id:) = raise(NotImplementedError)

    def find_stale_turns(before:) = []
  end
end
