# frozen_string_literal: true

module TurnKit
  module Record
    TURN_STATUSES = %w[pending running completed failed cancelled stale].freeze
    TOOL_EXECUTION_STATUSES = %w[pending running completed failed cancelled].freeze

    TURN_UPDATE_KEYS = %w[status options usage cost error output_text output_data started_at heartbeat_at completed_at].freeze
    TOOL_EXECUTION_UPDATE_KEYS = %w[status result error started_at completed_at].freeze

    module_function

    def conversation(attributes)
      attrs = stringify(attributes)
      now = Clock.now
      {
        "id" => attrs["id"] || Id.generate(:conversation),
        "agent_name" => attrs["agent_name"],
        "model" => attrs["model"],
        "subject" => attrs["subject"],
        "metadata" => attrs["metadata"] || {},
        "created_at" => attrs["created_at"] || now,
        "updated_at" => attrs["updated_at"] || now
      }
    end

    def message(attributes)
      Message.new(attributes).to_h
    end

    def turn(attributes)
      attrs = stringify(attributes)
      id = attrs["id"] || Id.generate(:turn)
      status = attrs["status"] || "pending"
      assert_status!(status, TURN_STATUSES, "turn")
      now = Clock.now
      {
        "id" => id,
        "conversation_id" => attrs.fetch("conversation_id"),
        "agent_name" => attrs["agent_name"],
        "parent_turn_id" => attrs["parent_turn_id"],
        "parent_tool_execution_id" => attrs["parent_tool_execution_id"],
        "root_turn_id" => attrs["root_turn_id"] || id,
        "context_message_sequence" => attrs["context_message_sequence"].to_i,
        "status" => status,
        "model" => attrs["model"],
        "options" => attrs["options"] || {},
        "usage" => attrs["usage"] || {},
        "cost" => attrs["cost"],
        "error" => attrs["error"],
        "output_text" => attrs["output_text"],
        "output_data" => attrs["output_data"],
        "started_at" => attrs["started_at"],
        "heartbeat_at" => attrs["heartbeat_at"],
        "completed_at" => attrs["completed_at"],
        "created_at" => attrs["created_at"] || now,
        "updated_at" => attrs["updated_at"] || now
      }
    end

    def tool_execution(attributes)
      attrs = stringify(attributes)
      status = attrs["status"] || "pending"
      assert_status!(status, TOOL_EXECUTION_STATUSES, "tool execution")
      now = Clock.now
      {
        "id" => attrs["id"] || Id.generate(:tool_execution),
        "turn_id" => attrs.fetch("turn_id"),
        "tool_call_id" => attrs.fetch("tool_call_id"),
        "tool_name" => attrs.fetch("tool_name"),
        "status" => status,
        "arguments" => attrs["arguments"] || {},
        "result" => attrs["result"],
        "error" => attrs["error"],
        "started_at" => attrs["started_at"],
        "completed_at" => attrs["completed_at"],
        "created_at" => attrs["created_at"] || now,
        "updated_at" => attrs["updated_at"] || now
      }
    end

    def turn_update(attributes)
      update(attributes, TURN_UPDATE_KEYS, TURN_STATUSES, "turn")
    end

    def tool_execution_update(attributes)
      update(attributes, TOOL_EXECUTION_UPDATE_KEYS, TOOL_EXECUTION_STATUSES, "tool execution")
    end

    def stringify(hash)
      hash.transform_keys(&:to_s)
    end

    def subject_pair(subject)
      case subject
      when Hash
        attrs = stringify(subject)
        [ attrs["type"] || attrs["class"], attrs["id"] ]
      else
        [ subject&.class&.name, subject&.respond_to?(:id) ? subject.id : nil ]
      end
    end

    def assert_status!(status, allowed, name)
      raise ArgumentError, "unknown #{name} status: #{status}" unless allowed.include?(status.to_s)
    end

    def update(attributes, allowed_keys, allowed_statuses, name)
      attrs = stringify(attributes)
      unknown = attrs.keys - allowed_keys
      raise ArgumentError, "unknown #{name} update attributes: #{unknown.join(", ")}" if unknown.any?

      assert_status!(attrs["status"], allowed_statuses, name) if attrs.key?("status")
      attrs
    end
  end
end
