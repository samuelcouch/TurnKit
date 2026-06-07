# frozen_string_literal: true

module TurnKit
  class ActiveRecordStore < Store
    def create_conversation(attributes)
      record = conversation_class.create!(record_attributes(attributes, id_key: "uid"))
      conversation_hash(record)
    end

    def load_conversation(id)
      conversation_hash(conversation_class.find_by!(uid: id))
    end

    def next_message_sequence(conversation_id)
      conversation_class.transaction do
        conversation = conversation_class.lock.find_by!(uid: conversation_id)
        message_class.where(conversation_uid: conversation.uid).maximum(:sequence).to_i + 1
      end
    end

    def latest_message_sequence(conversation_id)
      message_class.where(conversation_uid: conversation_id).maximum(:sequence).to_i
    end

    def append_message(attributes)
      attrs = attributes.transform_keys(&:to_s)
      sequence = nil
      message = nil
      record = conversation_class.transaction do
        conversation_class.lock.find_by!(uid: attrs.fetch("conversation_id"))
        sequence = message_class.where(conversation_uid: attrs.fetch("conversation_id")).maximum(:sequence).to_i + 1
        message = Record.message(attrs.merge("sequence" => sequence))
        message_class.create!(
          uid: message.fetch("id"),
          conversation_uid: message.fetch("conversation_id"),
          turn_uid: message["turn_id"],
          role: message.fetch("role"),
          kind: message.fetch("kind"),
          sequence: message.fetch("sequence"),
          content: message.fetch("content"),
          text: message.fetch("text"),
          tool_execution_uid: message["tool_execution_id"],
          provider_message_id: message["provider_message_id"],
          metadata: message.fetch("metadata")
        )
      end
      message_hash(record)
    end

    def list_messages(conversation_id, through_sequence: nil, turn_id: nil)
      scope = message_class.where(conversation_uid: conversation_id)
      if through_sequence
        scope = scope.where("sequence <= ? OR turn_uid = ?", through_sequence, turn_id)
      end
      scope.order(:sequence, :created_at, :uid).map { |record| message_hash(record) }
    end

    def create_turn(attributes)
      attrs = Record.turn(attributes)
      record_attrs = {
        uid: attrs.fetch("id"),
        conversation_uid: attrs.fetch("conversation_id"),
        agent_name: attrs["agent_name"],
        parent_turn_uid: attrs["parent_turn_id"],
        parent_tool_execution_uid: attrs["parent_tool_execution_id"],
        root_turn_uid: attrs.fetch("root_turn_id"),
        context_message_sequence: attrs["context_message_sequence"].to_i,
        status: attrs.fetch("status"),
        model: attrs["model"],
        options: attrs["options"] || {},
        usage: attrs["usage"] || {},
        cost: attrs["cost"],
        error: attrs["error"],
        output_text: attrs["output_text"],
        started_at: attrs["started_at"],
        heartbeat_at: attrs["heartbeat_at"],
        completed_at: attrs["completed_at"]
      }
      record_attrs[:output_data] = attrs["output_data"] if turn_has_attribute?("output_data")
      record = turn_class.create!(record_attrs)
      turn_hash(record)
    end

    def load_turn(id)
      turn_hash(turn_class.find_by!(uid: id))
    end

    def update_turn(id, attributes)
      record = turn_class.find_by!(uid: id)
      attrs = Record.turn_update(attributes)
      attrs.delete("output_data") unless turn_has_attribute?("output_data")
      record.update!(attrs)
      turn_hash(record)
    end

    def list_turns(root_turn_id: nil, conversation_id: nil, agent_name: nil)
      scope = turn_class.all
      scope = scope.where(root_turn_uid: root_turn_id) if root_turn_id
      scope = scope.where(conversation_uid: conversation_id) if conversation_id
      scope = scope.where(agent_name: agent_name) if agent_name
      scope.order(:created_at, :uid).map { |record| turn_hash(record) }
    end

    def create_tool_execution(attributes)
      attrs = Record.tool_execution(attributes)
      record = tool_execution_class.create!(
        uid: attrs.fetch("id"),
        turn_uid: attrs.fetch("turn_id"),
        tool_call_id: attrs.fetch("tool_call_id"),
        tool_name: attrs.fetch("tool_name"),
        status: attrs.fetch("status"),
        arguments: attrs["arguments"] || {},
        result: attrs["result"],
        error: attrs["error"],
        started_at: attrs["started_at"],
        completed_at: attrs["completed_at"]
      )
      tool_execution_hash(record)
    end

    def load_tool_execution(id)
      tool_execution_hash(tool_execution_class.find_by!(uid: id))
    end

    def update_tool_execution(id, attributes)
      record = tool_execution_class.find_by!(uid: id)
      record.update!(Record.tool_execution_update(attributes))
      tool_execution_hash(record)
    end

    def list_tool_executions(turn_id:)
      tool_execution_class.where(turn_uid: turn_id).order(:created_at, :uid).map { |record| tool_execution_hash(record) }
    end

    def find_stale_turns(before:)
      turn_class.where(status: %w[pending running]).where("COALESCE(heartbeat_at, started_at, created_at) < ?", before).map { |record| turn_hash(record) }
    end

    private
      def conversation_class = constantize(TurnKit.conversation_record_class || "Turnkit::Conversation")
      def turn_class = constantize(TurnKit.turn_record_class || "Turnkit::Turn")
      def message_class = constantize(TurnKit.message_record_class || "Turnkit::Message")
      def tool_execution_class = constantize(TurnKit.tool_execution_record_class || "Turnkit::ToolExecution")

      def constantize(name)
        name.to_s.split("::").inject(Object) { |mod, part| mod.const_get(part) }
      end

      def record_attributes(attributes, id_key:)
        attrs = Record.conversation(attributes)
        subject_type, subject_id = Record.subject_pair(attrs["subject"])
        {
          id_key => attrs.fetch("id"),
          agent_name: attrs["agent_name"],
          model: attrs["model"],
          subject_type: subject_type,
          subject_id: subject_id,
          metadata: attrs["metadata"] || {}
        }
      end

      def conversation_hash(record)
        { "id" => record.uid, "agent_name" => record.agent_name, "model" => record.model, "metadata" => record.metadata || {}, "created_at" => record.created_at, "updated_at" => record.updated_at }
      end

      def turn_hash(record)
        attrs = {
          "id" => record.uid, "conversation_id" => record.conversation_uid, "agent_name" => record.agent_name,
          "parent_turn_id" => record.parent_turn_uid, "parent_tool_execution_id" => record.parent_tool_execution_uid,
          "root_turn_id" => record.root_turn_uid, "context_message_sequence" => record.context_message_sequence,
          "status" => record.status, "model" => record.model, "options" => record.options || {}, "usage" => record.usage || {},
          "cost" => record.cost, "error" => record.error, "output_text" => record.output_text,
          "started_at" => record.started_at, "heartbeat_at" => record.heartbeat_at, "completed_at" => record.completed_at,
          "created_at" => record.created_at, "updated_at" => record.updated_at
        }
        attrs["output_data"] = record.output_data if record.respond_to?(:output_data)
        attrs
      end

      def turn_has_attribute?(name)
        turn_class.respond_to?(:attribute_names) && turn_class.attribute_names.include?(name)
      end

      def message_hash(record)
        {
          "id" => record.uid, "conversation_id" => record.conversation_uid, "turn_id" => record.turn_uid,
          "role" => record.role, "kind" => record.kind, "sequence" => record.sequence, "content" => record.content,
          "text" => record.text, "tool_execution_id" => record.tool_execution_uid,
          "provider_message_id" => record.provider_message_id, "metadata" => record.metadata || {}, "created_at" => record.created_at
        }
      end

      def tool_execution_hash(record)
        {
          "id" => record.uid, "turn_id" => record.turn_uid, "tool_call_id" => record.tool_call_id,
          "tool_name" => record.tool_name, "status" => record.status, "arguments" => record.arguments || {},
          "result" => record.result, "error" => record.error, "started_at" => record.started_at, "completed_at" => record.completed_at
        }
      end
  end
end
