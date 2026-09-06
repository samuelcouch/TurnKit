# frozen_string_literal: true

require "delegate"

module TurnKit
  # All writes made by an execution, including writes by tools and compaction,
  # are fenced by the same root lock used to revoke its claim.
  class ExecutionStore < SimpleDelegator
    def initialize(store, turn_id:, token:, conversation_id:)
      super(store)
      @turn_id, @token, @conversation_id = turn_id, token, conversation_id
    end

    def atomic(_conversation_id = nil)
      __getobj__.atomic(@conversation_id) do
        raise LostClaim, "turn ownership was revoked" unless load_turn(@turn_id)["claim_token"] == @token

        yield
      end
    end

    %i[create_conversation append_message next_message_sequence create_turn update_turn
       claim_turn create_tool_execution claim_tool_execution create_delivery update_delivery
       create_wait].each do |method|
      define_method(method) do |*args, **kwargs|
        atomic { __getobj__.public_send(method, *args, **kwargs) }
      end
    end
  end
end
