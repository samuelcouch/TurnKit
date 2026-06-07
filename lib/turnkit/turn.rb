# frozen_string_literal: true

module TurnKit
  class Turn
    STATUSES = Record::TURN_STATUSES

    attr_reader :agent, :conversation, :store, :budget, :depth
    attr_reader :id, :conversation_id, :agent_name, :parent_turn_id, :parent_tool_execution_id
    attr_reader :root_turn_id, :context_message_sequence, :model, :thinking, :compact, :output_schema
    attr_reader :started_at

    def initialize(agent:, conversation:, record:, store:, budget: nil, depth: 0, on_event: nil)
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
      @compact = compact_from_options
      @output_schema = output_schema_from_options
      @started_at = @record["started_at"]
      @budget = budget || agent.build_budget
      @depth = depth
      @on_event = on_event
    end

    def run!(&block)
      @on_event = block if block
      return self unless status == "pending"

      update!(status: "running", started_at: Clock.now, heartbeat_at: Clock.now)
      emit("turn.started", status: status, model: model)
      agent.effective_client.validate!(model: model)
      loop do
        budget.check!(depth: depth)
        budget.count_iteration!
        TurnKit::Compaction.maybe_compact!(self)

        request = model_request
        emit("model.requested", model: request.model, tool_names: request.tool_names)
        result = call_client(request)
        emit("model.completed", model: result.model || model, tool_call_count: result.tool_calls.length)
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
          update!(status: "completed", output_text: result.text, output_data: result.output_data, completed_at: Clock.now)
          emit("turn.completed", status: status, output_text: result.text)
          break
        end
      end
      reload
      self
    rescue StandardError => error
      update!(status: "failed", error: { "class" => error.class.name, "message" => error.message }, completed_at: Clock.now)
      emit("turn.failed", error: { "class" => error.class.name, "message" => error.message })
      reload
      self
    end

    def preview
      model_request
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

    def output_data
      @record["output_data"]
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
      @compact = compact_from_options
      @output_schema = output_schema_from_options
      self
    end

    def stale!
      update!(status: "stale", completed_at: Clock.now)
    end

    def emit(type, payload = {})
      emit_event(Event.new(type: type, turn_id: id, conversation_id: conversation.id, payload: payload))
    end

    private
      def model_request
        prompt = SystemPrompt.new(agent: agent, turn: self, conversation: conversation, mode: agent.effective_prompt_mode(turn: self))
        instructions = case agent.system_prompt
        when nil
          prompt.to_s
        when String
          agent.system_prompt
        else
          agent.system_prompt.call(prompt).to_s
        end
        ModelRequest.new(
          model: model,
          messages: llm_messages,
          tools: agent.effective_tools,
          instructions: instructions,
          thinking: thinking,
          output_schema: output_schema,
          metadata: { turn_id: id, conversation_id: conversation.id },
          report: prompt.report
        )
      end

      def call_client(request)
        kwargs = {
          model: request.model,
          messages: request.messages,
          tools: request.tools,
          instructions: request.instructions,
          thinking: request.thinking,
          output_schema: request.output_schema,
          metadata: request.metadata,
          on_event: ->(event) { emit_event(event) }
        }
        accepted = chat_keyword_names(agent.effective_client)
        kwargs = kwargs.slice(*accepted) unless accepted.include?(:keyrest)
        agent.effective_client.chat(**kwargs)
      end

      def chat_keyword_names(client)
        client.method(:chat).parameters.filter_map do |kind, name|
          return [ :keyrest ] if kind == :keyrest

          name if %i[key keyreq].include?(kind)
        end
      end

      def llm_messages
        MessageProjection.for(TurnKit::Compaction.project(conversation.messages_for_turn(self)))
      end

      def thinking_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        return Agent.normalize_thinking(options["thinking"]) if options.key?("thinking")

        agent.effective_thinking
      end

      def compact_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["compact"] if options.key?("compact")
      end

      def output_schema_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["output_schema"] if options.key?("output_schema")
      end

      def persist_assistant_message(result)
        if result.tool_calls?
          message = conversation.append_message(
            role: "assistant",
            kind: "tool_call",
            text: result.text,
            turn_id: id,
            metadata: { "tool_calls" => result.tool_calls.map { |call| { "id" => call.id, "name" => call.name, "arguments" => call.arguments } } }
          )
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
          result.tool_calls.each { |call| emit("tool_call.created", id: call.id, name: call.name) }
        else
          message = conversation.append_message(role: "assistant", kind: "text", text: result.text, turn_id: id, metadata: { "output_data" => result.output_data }.compact)
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
        end
      end

      def complete_from_terminal_tool(runner, execution)
        message = runner.completion_message(execution)
        assistant = conversation.append_message(role: "assistant", kind: "text", text: message, turn_id: id)
        emit("message.created", message_id: assistant.id, role: assistant.role, kind: assistant.kind)
        update!(status: "completed", output_text: message, completed_at: Clock.now)
        emit("turn.completed", status: status, output_text: message)
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

      def emit_event(event)
        event = Event.new(type: event[:type] || event["type"], turn_id: id, conversation_id: conversation.id, payload: event[:payload] || event["payload"] || {}) if event.is_a?(Hash)
        Array(@on_event || agent.effective_on_event).each { |callback| callback.call(event) }
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
