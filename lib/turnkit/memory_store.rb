# frozen_string_literal: true

require "monitor"

module TurnKit
  class MemoryStore < Store
    def initialize
      @mutex = Monitor.new
      @conversations = {}
      @turns = {}
      @messages = {}
      @tool_executions = {}
      @deliveries = {}
      @delivery_keys = {}
      @waits = {}
      @message_sequences = Hash.new(0)
      @transaction_depth = 0
    end

    def atomic(_conversation_id)
      @mutex.synchronize do
        snapshot = Marshal.dump([@conversations, @turns, @messages, @tool_executions, @deliveries, @delivery_keys, @waits, @message_sequences]) if @transaction_depth.zero?
        @transaction_depth += 1
        committed = false
        begin
          result = yield
          committed = true
          result
        ensure
          @transaction_depth -= 1
          if snapshot && !committed
            @conversations, @turns, @messages, @tool_executions, @deliveries, @delivery_keys, @waits, @message_sequences = Marshal.load(snapshot)
          end
        end
      end
    end
    def atomic_graph(&block) = atomic(nil, &block)

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

    def claim_turn(id, from: "pending", to: "running", **attributes)
      attrs = Record.turn_update(attributes.merge(status: to))
      @mutex.synchronize do
        record = @turns.fetch(id)
        return nil unless record["status"] == from

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

    def list_submitted_turns(limit: nil)
      @mutex.synchronize do
        rows = @turns.values.select { |turn| turn["submitted_at"] }.sort_by { |turn| [ turn["created_at"].to_f, turn["id"] ] }
        rows = rows.first(limit) if limit
        rows.map { |turn| duplicate(turn) }
      end
    end

    def list_actionable_turns(limit:)
      @mutex.synchronize do
        @turns.values.select { |turn| turn["submitted_at"] && %w[pending waiting running].include?(turn["status"]) }
          .sort_by { |turn| [ turn["updated_at"].to_f, turn["id"] ] }.first(limit).map { |turn| duplicate(turn) }
      end
    end

    def list_stale_inline_turns(before:, limit:)
      @mutex.synchronize do
        @turns.values.select { |row| !row["submitted_at"] && %w[pending running].include?(row["status"]) &&
          (row["heartbeat_at"] || row["started_at"] || row["created_at"]) < before }
          .sort_by { |row| [row["updated_at"].to_f, row["id"]] }.first(limit).map { |row| duplicate(row) }
      end
    end

    def create_delivery(attributes)
      record = Record.delivery(attributes)
      @mutex.synchronize do
        existing_id = @delivery_keys[record.fetch("key")]
        if existing_id
          existing = @deliveries.fetch(existing_id)
          Record.assert_delivery_retry!(existing, record)
          return duplicate(existing)
        end

        @deliveries[record.fetch("id")] = record
        @delivery_keys[record.fetch("key")] = record.fetch("id")
        duplicate(record)
      end
    end

    def load_delivery(id)
      @mutex.synchronize { duplicate(@deliveries.fetch(id)) }
    end

    def update_delivery(id, attributes)
      attrs = Record.delivery_update(attributes)
      @mutex.synchronize do
        @deliveries.fetch(id).merge!(attrs)
        duplicate(@deliveries.fetch(id))
      end
    end

    def list_deliveries(source_conversation_id: nil, destination_conversation_id: nil, pending: false, limit: nil)
      @mutex.synchronize do
        rows = @deliveries.values
        rows = rows.select { |row| row["source_conversation_id"] == source_conversation_id } if source_conversation_id
        rows = rows.select { |row| row["destination_conversation_id"] == destination_conversation_id } if destination_conversation_id
        rows = rows.select { |row| row["delivered_at"].nil? } if pending
        rows = rows.sort_by { |row| [ row["created_at"].to_f, row["id"] ] }
        rows = rows.first(limit) if limit
        rows.map { |row| duplicate(row) }
      end
    end

    def create_wait(turn_id:, target_turn_id:)
      @mutex.synchronize do
        wait = { "turn_id" => turn_id, "target_turn_id" => target_turn_id }
        @waits[[ turn_id, target_turn_id ]] ||= wait
        duplicate(@waits.fetch([ turn_id, target_turn_id ]))
      end
    end

    def list_waits(turn_id: nil, target_turn_id: nil)
      @mutex.synchronize do
        rows = @waits.values
        rows = rows.select { |row| row["turn_id"] == turn_id } if turn_id
        rows = rows.select { |row| row["target_turn_id"] == target_turn_id } if target_turn_id
        rows.map { |row| duplicate(row) }
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

    def claim_tool_execution(id, from: "running", to: "completed", **attributes)
      attrs = Record.tool_execution_update(attributes.merge(status: to))
      @mutex.synchronize do
        record = @tool_executions.fetch(id)
        return nil unless record["status"] == from

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

    private
      def stringify(hash)
        hash.transform_keys(&:to_s)
      end

      def duplicate(value)
        Marshal.load(Marshal.dump(value))
      end

  end
end
