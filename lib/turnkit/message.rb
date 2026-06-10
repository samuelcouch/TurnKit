# frozen_string_literal: true

module TurnKit
  class Message
    ROLES = %w[user assistant tool].freeze
    KINDS = %w[text tool_call tool_result context_summary].freeze

    attr_reader :id, :conversation_id, :turn_id, :role, :kind, :sequence
    attr_reader :content, :tool_execution_id, :provider_message_id, :metadata, :created_at

    def initialize(attributes = {})
      attrs = stringify(attributes)
      @id = attrs["id"] || Id.generate(:message)
      @conversation_id = attrs.fetch("conversation_id")
      @turn_id = attrs["turn_id"]
      @role = attrs.fetch("role").to_s
      @kind = attrs.fetch("kind", "text").to_s
      @sequence = attrs.fetch("sequence").to_i
      @content = normalize_content(attrs["content"].nil? ? attrs["text"] : attrs["content"])
      @tool_execution_id = attrs["tool_execution_id"]
      @provider_message_id = attrs["provider_message_id"]
      @metadata = attrs["metadata"] || {}
      @created_at = attrs["created_at"] || Clock.now

      validate!
    end

    def to_h
      {
        "id" => id,
        "conversation_id" => conversation_id,
        "turn_id" => turn_id,
        "role" => role,
        "kind" => kind,
        "sequence" => sequence,
        "content" => content,
        "tool_execution_id" => tool_execution_id,
        "provider_message_id" => provider_message_id,
        "metadata" => metadata,
        "created_at" => created_at
      }
    end

    def text?
      kind == "text"
    end

    def tool_call?
      kind == "tool_call"
    end

    def tool_result?
      kind == "tool_result"
    end

    def context_summary?
      kind == "context_summary"
    end

    def text
      content.filter_map do |part|
        attrs = stringify(part)
        attrs["text"] if attrs["type"] == "text"
      end.join("\n")
    end

    def compaction_metadata
      metadata.fetch("compaction", {})
    end

    private
      def stringify(hash)
        hash.transform_keys(&:to_s)
      end

      def normalize_content(value)
        return Array(value).map { |part| normalize_part(part) } if value.is_a?(Array)

        [ { "type" => "text", "text" => value.to_s } ]
      end

      def normalize_part(part)
        attrs = part.respond_to?(:to_h) ? part.to_h.transform_keys(&:to_s) : { "type" => "text", "text" => part.to_s }
        attrs["type"] ||= "text"
        attrs
      end

      def validate!
        raise ArgumentError, "unknown role: #{role}" unless ROLES.include?(role)
        raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)
        raise ArgumentError, "sequence must be positive" unless sequence.positive?
      end
  end
end
