# frozen_string_literal: true

module TurnKit
  class MemoryStore < Store
    def initialize
      @mutex = Mutex.new
      @conversations = {}
      @turns = {}
      @messages = {}
      @tool_executions = {}
      @message_sequences = Hash.new(0)
    end

    def create_conversation(attributes)
      record = Record.conversation(attributes)

      @mutex.synchronize { @conversations[record.fetch("id")] = record }
      record.dup
    end

    def load_conversation(id)
      @mutex.synchronize { duplicate(@conversations.fetch(id)) }
    end

    def next_message_sequence(conversation_id)
      @mutex.synchronize do
        @message_sequences[conversation_id] += 1
      end
    end

    def latest_message_sequence(conversation_id)
      @mutex.synchronize { @message_sequences[conversation_id].to_i }
    end

    def append_message(attributes)
      attrs = stringify(attributes)
      attrs["sequence"] ||= next_message_sequence(attrs.fetch("conversation_id"))
      message = Record.message(attrs)
      @mutex.synchronize { @messages[message.fetch("id")] = message }
      duplicate(message)
    end

    def list_messages(conversation_id, through_sequence: nil, turn_id: nil)
      @mutex.synchronize do
        rows = @messages.values.select { |message| message["conversation_id"] == conversation_id }
        rows = rows.select { |message| message["sequence"].to_i <= through_sequence.to_i || message["turn_id"] == turn_id } if through_sequence
        rows.sort_by { |message| [ message["sequence"].to_i, message["created_at"].to_f, message["id"] ] }.map { |message| duplicate(message) }
      end
    end

    def create_turn(attributes)
      record = Record.turn(attributes)

      @mutex.synchronize { @turns[record.fetch("id")] = record }
      duplicate(record)
    end

    def load_turn(id)
      @mutex.synchronize { duplicate(@turns.fetch(id)) }
    end

    def update_turn(id, attributes)
      attrs = Record.turn_update(attributes)
      @mutex.synchronize do
        record = @turns.fetch(id)
        record.merge!(attrs.merge("updated_at" => Clock.now))
        duplicate(record)
      end
    end

    def list_turns(root_turn_id: nil, conversation_id: nil, agent_name: nil)
      @mutex.synchronize do
        rows = @turns.values
        rows = rows.select { |turn| turn["root_turn_id"] == root_turn_id } if root_turn_id
        rows = rows.select { |turn| turn["conversation_id"] == conversation_id } if conversation_id
        rows = rows.select { |turn| turn["agent_name"] == agent_name } if agent_name
        rows.sort_by { |turn| [ turn["created_at"].to_f, turn["id"] ] }.map { |turn| duplicate(turn) }
      end
    end

    def create_tool_execution(attributes)
      record = Record.tool_execution(attributes)

      @mutex.synchronize { @tool_executions[record.fetch("id")] = record }
      duplicate(record)
    end

    def load_tool_execution(id)
      @mutex.synchronize { duplicate(@tool_executions.fetch(id)) }
    end

    def update_tool_execution(id, attributes)
      attrs = Record.tool_execution_update(attributes)
      @mutex.synchronize do
        record = @tool_executions.fetch(id)
        record.merge!(attrs.merge("updated_at" => Clock.now))
        duplicate(record)
      end
    end

    def list_tool_executions(turn_id:)
      @mutex.synchronize do
        @tool_executions.values
          .select { |execution| execution["turn_id"] == turn_id }
          .sort_by { |execution| [ execution["created_at"].to_f, execution["id"] ] }
          .map { |execution| duplicate(execution) }
      end
    end

    def find_stale_turns(before:)
      @mutex.synchronize do
        @turns.values.select do |turn|
          %w[pending running].include?(turn["status"]) && stale_anchor(turn) && stale_anchor(turn) < before
        end.map { |turn| duplicate(turn) }
      end
    end

    private
      def stringify(hash)
        hash.transform_keys(&:to_s)
      end

      def duplicate(value)
        Marshal.load(Marshal.dump(value))
      end

      def stale_anchor(turn)
        turn["heartbeat_at"] || turn["started_at"] || turn["created_at"]
      end
  end
end
