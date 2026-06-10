# frozen_string_literal: true

module TurnKit
  class Turn
    STATUSES = Record::TURN_STATUSES

    attr_reader :agent, :conversation, :store, :budget, :depth
    attr_reader :id, :conversation_id, :agent_name, :parent_turn_id, :parent_tool_execution_id
    attr_reader :root_turn_id, :context_message_sequence, :model, :thinking, :compact, :output_schema, :prompt_mode
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
      @prompt_mode = prompt_mode_from_options
      @started_at = @record["started_at"]
      @budget = budget || agent.build_budget
      @depth = depth
      @on_event = on_event
    end

    def run!(&block)
      @on_event = block if block
      return self unless status == "pending"

      claimed = store.claim_turn(id, from: "pending", to: "running", started_at: Clock.now, heartbeat_at: Clock.now)
      return self unless claimed

      @record = claimed
      @started_at = @record["started_at"]
      emit("turn.started", status: status, model: model)
      agent.effective_client.validate!(model: model)
      @budget = Budget.resume(store: store, root_turn_id: root_turn_id, limits: budget_limits)
      revisions_used = 0
      loop do
        budget.check!(depth: depth)
        count_iteration!
        TurnKit::Compaction.maybe_compact!(self)

        request = model_request
        emit_model_requested("model.requested", request)
        result = call_client(request)
        result_cost = Cost.from_usage(result.usage, model: result.model || model)

        add_usage!(result.usage, cost: result_cost)
        emit_model_completed("model.completed", result, result_cost, model: model)
        budget.add_cost!(result_cost.total)
        persist_assistant_message(result)

        if result.tool_calls?
          runner = ToolRunner.new(self)
          terminal = runner.dispatch(result.tool_calls)
          if terminal
            candidate = append_terminal_completion(runner, terminal)
          else
            next
          end
        else
          candidate = result.text
        end

        audit = check_policy(candidate, output_data: result.output_data)
        if should_revise?(audit, revisions_used)
          revisions_used += 1
          append_revision_message(audit, attempt: revisions_used, terminal_tool_name: terminal&.tool_name)
          emit("output_policy.revision", violation_count: audit.violations.length, attempt: revisions_used)
          next
        end

        complete_with_output(candidate, output_data: result.output_data, audit: audit)
        break
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

    def policy_audit
      (@record["options"] || {})["policy_audit"]
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
      @prompt_mode = prompt_mode_from_options
      self
    end

    def stale!
      update!(status: "stale", completed_at: Clock.now)
    end

    def emit(type, payload = {})
      emit_event(Event.new(type: type, turn_id: id, conversation_id: conversation.id, payload: payload))
    end

    def internal_model_call(model:, messages:, instructions:, tools: [], thinking: nil, output_schema: nil, metadata: {}, purpose:, client: nil)
      request = ModelRequest.new(
        model: model,
        messages: messages,
        tools: tools,
        instructions: instructions,
        thinking: thinking,
        output_schema: output_schema,
        metadata: { purpose: purpose.to_s, turn_id: id, conversation_id: conversation.id }.merge(metadata || {})
      )
      model_client = client || agent.effective_client
      model_client.validate!(model: request.model)

      emit_model_requested("#{purpose}.model.requested", request)
      result = call_client(request, client: model_client)
      result_cost = Cost.from_usage(result.usage, model: result.model || request.model)
      add_usage!(result.usage, cost: result_cost)
      emit_model_completed("#{purpose}.model.completed", result, result_cost, model: request.model)
      budget.add_cost!(result_cost.total)
      result
    end

    private
      def model_request
        prompt = SystemPrompt.new(agent: agent, turn: self, conversation: conversation, mode: prompt_mode || agent.effective_prompt_mode(turn: self))
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

      def call_client(request, client: agent.effective_client)
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
        accepted = chat_keyword_names(client)
        kwargs = kwargs.slice(*accepted) unless accepted.include?(:keyrest)
        client.chat(**kwargs)
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

      def emit_model_requested(type, request)
        emit(
          type,
          model: request.model,
          tool_names: request.tool_names,
          message_count: request.messages.length,
          prompt: request.report
        )
      end

      def emit_model_completed(type, result, cost, model: self.model)
        emit(
          type,
          model: result.model || model,
          tool_call_count: result.tool_calls.length,
          usage: result.usage.to_h,
          cost: cost.to_h
        )
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

      def prompt_mode_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["prompt_mode"]&.to_sym if options.key?("prompt_mode")
      end

      def persist_assistant_message(result)
        if result.tool_calls?
          message = conversation.append_message(
            role: "assistant",
            kind: "tool_call",
            content: result.parts,
            turn_id: id,
            metadata: {}
          )
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
          result.tool_calls.each { |call| emit("tool_call.created", id: call.id, name: call.name) }
        else
          message = conversation.append_message(role: "assistant", kind: "text", text: result.text, turn_id: id, metadata: { "output_data" => result.output_data }.compact)
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
        end
      end

      def append_terminal_completion(runner, execution)
        message = runner.completion_message(execution)
        assistant = conversation.append_message(role: "assistant", kind: "text", text: message, turn_id: id)
        emit("message.created", message_id: assistant.id, role: assistant.role, kind: assistant.kind)
        message
      end

      def complete_with_output(text, output_data: nil, audit: nil)
        attrs = { output_text: text, output_data: output_data, completed_at: Clock.now }
        if audit && !audit.clean? && agent.output_policy_mode == :fail
          attrs[:status] = "failed"
          attrs[:error] = { "class" => "TurnKit::OutputAudit", "message" => audit.messages.join("; "), "policy_audit" => audit.to_h }
        else
          attrs[:status] = "completed"
        end
        update!(attrs)
        persist_policy_audit(audit) if audit

        if failed?
          emit("turn.failed", error: @record["error"])
        else
          emit("turn.completed", status: status, output_text: text)
        end
      end

      def check_policy(text, output_data: nil)
        constraints = agent.effective_output_policy
        return nil if constraints.empty?

        output = output_data.nil? ? text : output_data
        TurnKit.check_output_policy(output, constraints: constraints, context: { turn: self, output_text: text, output_data: output_data })
      end

      def persist_policy_audit(audit)
        options = (@record["options"] || {}).merge("policy_audit" => audit.to_h)
        update!(options: options)
        emit("output_policy.completed", clean: audit.clean?, violation_count: audit.violations.length)
      end

      def should_revise?(audit, revisions_used)
        audit && !audit.clean? && revisions_used < agent.output_retries
      end

      def append_revision_message(audit, attempt:, terminal_tool_name: nil)
        text = <<~TEXT.strip
          The previous output failed policy checks.

          Revise the previous output. Do not introduce new claims.
          Do not deviate from the skill or policy below.

          #{revision_policy_blocks}

          Violations:
          #{audit.violations.each_with_index.map { |violation, index| "#{index + 1}. #{violation.rule}: #{violation.message}" }.join("\n")}
          #{terminal_tool_name ? "\nResubmit via #{terminal_tool_name}." : ""}
        TEXT
        message = conversation.append_message(role: "user", kind: "text", text: text, turn_id: id, metadata: { "source" => "output_policy", "attempt" => attempt })
        emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def revision_policy_blocks
        agent.effective_output_policy.filter_map do |policy|
          next unless policy.respond_to?(:content)

          key = policy.respond_to?(:name) ? policy.name : "output_policy"
          "<skill key=\"#{key}\">\n#{policy.content}\n</skill>"
        end.join("\n\n")
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

      def count_iteration!
        budget.count_iteration!
        options = (@record["options"] || {}).merge("iterations" => (@record.dig("options", "iterations").to_i + 1))
        update!(options: options)
      end

      def heartbeat!
        update!(heartbeat_at: Clock.now)
      end

      def budget_limits
        {
          max_iterations: agent.max_iterations || TurnKit.max_iterations,
          timeout: agent.timeout || TurnKit.timeout,
          max_depth: agent.max_depth || TurnKit.max_depth,
          max_tool_executions: agent.max_tool_executions || TurnKit.max_tool_executions,
          max_tool_executions_by_name: agent.max_tool_executions_by_name || TurnKit.max_tool_executions_by_name,
          max_spend: agent.max_spend || TurnKit.max_spend
        }
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
