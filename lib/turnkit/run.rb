# frozen_string_literal: true

module TurnKit
  class Run
    attr_reader :turn

    def initialize(turn)
      @turn = turn
    end

    def id = turn.id
    def root_turn_id = turn.root_turn_id
    def status = turn.status
    def output = output_text
    def output_text = turn.output_text
    def output_data = turn.output_data
    def policy_audit = turn.policy_audit
    def policy_clean? = policy_audit.nil? || policy_audit.fetch("clean", false)
    def usage = Usage.from_records(turn_records)
    def cost = Cost.from_records(turn_records)
    def steps = turn_records.length
    def tool_calls = tool_executions
    def persisted? = true

    def error
      turn.store.load_turn(id)["error"]
    end

    def messages
      turn_records.map { |record| record.fetch("conversation_id") }.uniq.flat_map do |conversation_id|
        turn.store.list_messages(conversation_id).map { |attrs| Message.new(attrs) }
      end
    end

    Turn::STATUSES.each do |state|
      define_method("#{state}?") { status == state }
    end

    def run!(&block)
      turn.run!(&block)
      self
    end

    def reload
      turn.reload
      self
    end

    def preview
      turn.preview
    end

    def tool_executions
      turn_records.flat_map do |record|
        turn.store.list_tool_executions(turn_id: record.fetch("id")).map { |attrs| ToolExecution.new(attrs) }
      end
    end

    def turn_records
      turn.store.list_turns(root_turn_id: root_turn_id)
    end

    def child_turn_records
      turn_records.select { |record| record["parent_turn_id"] == id }
    end

    def descendant_turn_records
      turn_records.reject { |record| record.fetch("id") == id }
    end

    def failed_turn_records
      turn_records.select { |record| record["status"] == "failed" }
    end
  end
end
