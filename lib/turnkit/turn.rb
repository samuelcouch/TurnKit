# frozen_string_literal: true

module TurnKit
  class Turn
    STATUSES = Record::TURN_STATUSES

    attr_reader :agent, :conversation, :store, :budget, :depth
    attr_reader :id, :conversation_id, :agent_name, :parent_turn_id, :parent_tool_execution_id
    attr_reader :root_turn_id, :context_message_sequence, :model, :thinking
    attr_reader :started_at

    def initialize(agent:, conversation:, record:, store:, budget: nil, depth: 0)
      @agent = agent
      @conversation = conversation
      @store = store
      @record = record.transform_keys(&:to_s)
      @id = @record.fetch("id")
      @conversation_id = @record.fetch("conversation_id")
      @agent_name = @record["agent_name"]
      @parent_turn_id = @record["parent_turn_id"]
      @parent_tool_execution_id = @record["parent_tool_execution_id"]
      @root_turn_id = @record["root_turn_id"] || id
      @context_message_sequence = @record["context_message_sequence"].to_i
      @model = @record["model"] || agent.effective_model
      @thinking = thinking_from_options
      @started_at = @record["started_at"]
      @budget = budget || agent.build_budget
      @depth = depth
    end

    def run!
      return self unless status == "pending"

      update!(status: "running", started_at: Clock.now, heartbeat_at: Clock.now)
      loop do
        budget.check!(depth: depth)
        budget.count_iteration!

        result = agent.effective_client.chat(
          model: model,
          messages: llm_messages,
          tools: agent.effective_tools,
          instructions: agent.system_prompt_for(turn: self, conversation: conversation),
          thinking: thinking,
          metadata: { turn_id: id, conversation_id: conversation.id }
        )
        result_cost = Cost.from_usage(result.usage, model: result.model || model)

        budget.add_cost!(result_cost.total)
        add_usage!(result.usage, cost: result_cost)
        persist_assistant_message(result)

        if result.tool_calls?
          runner = ToolRunner.new(self)
          terminal = runner.dispatch(result.tool_calls)
          if terminal
            complete_from_terminal_tool(runner, terminal)
            break
          end
        else
          update!(status: "completed", output_text: result.text, completed_at: Clock.now)
          break
        end
      end
      reload
      self
    rescue StandardError => error
      update!(status: "failed", error: { "class" => error.class.name, "message" => error.message }, completed_at: Clock.now)
      reload
      self
    end

    def status
      @record.fetch("status")
    end

    STATUSES.each do |state|
      define_method("#{state}?") { status == state }
    end

    def output_text
      @record["output_text"].to_s
    end

    def usage
      Usage.from_h(@record["usage"] || {})
    end

    def cost
      Cost.from_record(@record)
    end

    def tool_executions
      store.list_tool_executions(turn_id: id).map { |attrs| ToolExecution.new(attrs) }
    end

    def reload
      @record = store.load_turn(id)
      @thinking = thinking_from_options
      self
    end

    def stale!
      update!(status: "stale", completed_at: Clock.now)
    end

    private
      def llm_messages
        MessageProjection.for(conversation.messages_for_turn(self))
      end

      def thinking_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        return Agent.normalize_thinking(options["thinking"]) if options.key?("thinking")

        agent.effective_thinking
      end

      def persist_assistant_message(result)
        if result.tool_calls?
          conversation.append_message(
            role: "assistant",
            kind: "tool_call",
            text: result.text,
            turn_id: id,
            metadata: { "tool_calls" => result.tool_calls.map { |call| { "id" => call.id, "name" => call.name, "arguments" => call.arguments } } }
          )
        else
          conversation.append_message(role: "assistant", kind: "text", text: result.text, turn_id: id)
        end
      end

      def complete_from_terminal_tool(runner, execution)
        message = runner.completion_message(execution)
        conversation.append_message(role: "assistant", kind: "text", text: message, turn_id: id)
        update!(status: "completed", output_text: message, completed_at: Clock.now)
      end

      def add_usage!(usage, cost: nil)
        current = @record["usage"] || {}
        totals = {
          "input_tokens" => current["input_tokens"].to_i + usage.input_tokens,
          "output_tokens" => current["output_tokens"].to_i + usage.output_tokens,
          "cached_tokens" => current["cached_tokens"].to_i + usage.cached_tokens,
          "cache_write_tokens" => current["cache_write_tokens"].to_i + usage.cache_write_tokens,
          "thinking_tokens" => current["thinking_tokens"].to_i + usage.thinking_tokens,
          "total_tokens" => current["total_tokens"].to_i + usage.total_tokens
        }
        totals["cost_details"] = aggregate_cost(current["cost_details"], cost).to_h if cost&.total
        attributes = { usage: totals, heartbeat_at: Clock.now }
        attributes[:cost] = @record["cost"].to_f + cost.total if cost&.total
        update!(attributes)
      end

      def aggregate_cost(current, cost)
        return cost unless current

        Cost.aggregate([ Cost.from_hash(current), cost ])
      end

      def update!(attributes)
        @record = store.update_turn(id, attributes)
        @started_at = @record["started_at"]
        @model = @record["model"] || agent.effective_model
        @record
      end
  end

  class ToolContext
    attr_reader :turn, :execution

    def initialize(turn:, execution:)
      @turn = turn
      @execution = execution
    end
  end
end
