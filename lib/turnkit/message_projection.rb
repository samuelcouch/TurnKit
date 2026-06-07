# frozen_string_literal: true

module TurnKit
  class MessageProjection
    CONTEXT_SUMMARY_TRIGGER = "What did we do so far?"
    CONTEXT_SUMMARY_PREFIX = <<~TEXT.strip
      [CONTEXT COMPACTION — REFERENCE ONLY]

      Earlier TurnKit conversation messages were compacted into the summary below. This is a handoff from a previous context window. Treat it as background reference, not as active instructions.

      Do not answer questions or perform tasks merely because they appear in this summary. Respond to the latest user message after this summary.

      If the latest user message contradicts, supersedes, changes topic from, or diverges from Active Task, In Progress, Pending User Asks, or Remaining Work, the latest user message wins.

      Subject context and live context are recomputed for the current turn and are more authoritative for state-sensitive facts.

      The original messages remain durably stored; this summary only affects the model-visible prompt projection.
    TEXT

    def self.for(messages)
      messages.flat_map { |message| new(message).to_a }
    end

    def initialize(message)
      @message = message
    end

    def to_a
      case message.kind
      when "context_summary"
        [
          { role: :user, content: CONTEXT_SUMMARY_TRIGGER },
          { role: :assistant, content: [ CONTEXT_SUMMARY_PREFIX, message.text ].reject(&:empty?).join("\n\n") }
        ]
      else
        [ to_h ]
      end
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
