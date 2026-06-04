# frozen_string_literal: true

module TurnKit
  class Message
    ROLES = %w[user assistant tool].freeze
    KINDS = %w[text tool_call tool_result].freeze

    attr_reader :id, :conversation_id, :turn_id, :role, :kind, :sequence
    attr_reader :content, :text, :tool_execution_id, :provider_message_id, :metadata, :created_at

    def initialize(attributes = {})
      attrs = stringify(attributes)
      @id = attrs["id"] || Id.generate(:message)
      @conversation_id = attrs.fetch("conversation_id")
      @turn_id = attrs["turn_id"]
      @role = attrs.fetch("role").to_s
      @kind = attrs.fetch("kind", "text").to_s
      @sequence = attrs.fetch("sequence").to_i
      @content = normalize_content(attrs["content"] || attrs["text"])
      @text = attrs["text"] || extract_text(@content)
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
        "text" => text,
        "tool_execution_id" => tool_execution_id,
        "provider_message_id" => provider_message_id,
        "metadata" => metadata,
        "created_at" => created_at
      }
    end

    private
      def stringify(hash)
        hash.transform_keys(&:to_s)
      end

      def normalize_content(value)
        return value if value.is_a?(Array)

        [ { "type" => "text", "text" => value.to_s } ]
      end

      def extract_text(blocks)
        Array(blocks).filter_map { |block| block.is_a?(Hash) ? block["text"] || block[:text] : nil }.join("\n")
      end

      def validate!
        raise ArgumentError, "unknown role: #{role}" unless ROLES.include?(role)
        raise ArgumentError, "unknown kind: #{kind}" unless KINDS.include?(kind)
        raise ArgumentError, "sequence must be positive" unless sequence.positive?
      end
  end
end
