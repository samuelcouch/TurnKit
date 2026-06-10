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
        { role: :assistant, content: projected_content, tool_calls: tool_call_parts }
      when "tool_result"
        part = message.content.find { |candidate| candidate.fetch("type") == "tool_result" }
        { role: :tool, content: part&.fetch("text", message.text) || message.text, tool_call_id: part&.fetch("tool_call_id", nil) }
      else
        { role: message.role.to_sym, content: message.text }
      end
    end

    private
      attr_reader :message

      def projected_content
        parts = message.content.reject { |part| %w[tool_call provider].include?(part.fetch("type")) }
        ordered = parts.select { |part| part.fetch("type") == "thinking" } + parts.select { |part| part.fetch("type") == "text" }
        ordered.filter_map { |part| part.fetch("text", nil) }.join("\n")
      end

      def tool_call_parts
        message.content.filter_map do |part|
          next unless part.fetch("type") == "tool_call"

          { "id" => part.fetch("id"), "name" => part.fetch("name"), "arguments" => part["arguments"] || {} }
        end
      end
  end
end
