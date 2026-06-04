# frozen_string_literal: true

module TurnKit
  class MessageProjection
    def self.for(messages)
      messages.map { |message| new(message).to_h }
    end

    def initialize(message)
      @message = message
    end

    def to_h
      case message.kind
      when "tool_call"
        { role: :assistant, content: message.text, tool_calls: message.metadata.fetch("tool_calls", []) }
      when "tool_result"
        { role: :tool, content: message.text, tool_call_id: message.metadata["tool_call_id"] }
      else
        { role: message.role.to_sym, content: message.text }
      end
    end

    private
      attr_reader :message
  end
end
