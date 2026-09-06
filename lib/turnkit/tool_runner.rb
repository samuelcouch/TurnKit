# frozen_string_literal: true

module TurnKit
  class ToolRunner
    def initialize(turn)
      @turn = turn
    end

    def dispatch(tool_calls)
      waiting = false
      tool_calls.each_with_index do |tool_call, index|
        # Fan out a contiguous group of subagents, but never reorder ordinary
        # tools across it or execute past a terminal tool.
        return :waiting if waiting && !subagent?(tool_for(tool_call.name))
        execution = run(tool_call, defer_result: waiting)
        if execution == :waiting
          waiting = true
          next
        end
        if execution.completed? && tool_for(tool_call.name)&.ends_turn?
          skip_remaining(tool_calls.drop(index + 1), terminal: tool_call)
          return execution
        end
      end
      waiting ? :waiting : nil
    end

    def completion_message(execution)
      tool = tool_for(execution.tool_name)
      tool.completion_message(execution.result) || execution.result&.fetch("result", nil) || "Completed via #{execution.tool_name}."
    end

    private
      attr_reader :turn

      def run(tool_call, defer_result: false)
        @defer_result = defer_result
        tool = tool_for(tool_call.name)
        existing = turn.store.list_tool_executions(turn_id: turn.id).find { |row| row["tool_call_id"] == tool_call.id }
        if existing && !%w[pending running].include?(existing["status"])
          execution = ToolExecution.new(existing)
          append_result_once(execution, tool_call, execution.result || execution.error, error: !execution.completed? && !execution.cancelled?)
          return execution
        end

        denied = nil
        execution = turn.store.atomic do
          execution = ToolExecution.new(existing || create_execution(tool_call))
          unless existing
            begin
              turn.execution_budget(excluding: execution.id).count_tool_execution!(tool_call.name)
            rescue BudgetError => error
              denied = error
              finish_error(execution, tool_call, error.message, details: { "class" => error.class.name, "budget_denied" => true })
            end
          end
          execution
        end
        raise denied if denied

        unless tool
          return finish_error(execution, tool_call, "unknown tool: #{tool_call.name}")
        end

        if tool_call.arguments_error
          return finish_error(execution, tool_call, tool_call.arguments_error)
        end

        if execution.status == "pending" && !subagent?(tool) && ![WaitTool, LaunchAgentTool, SendMessageTool].include?(tool)
          claimed = turn.store.claim_tool_execution(execution.id, from: "pending", to: "running", started_at: Clock.now)
          raise LostClaim, "tool execution claim was revoked" unless claimed
          execution = ToolExecution.new(claimed)
        end

        context = ToolContext.new(turn: turn, execution: execution)
        payload = begin
          Authorization.authorize!(:tool, principal: context.principal, turn: turn, tool: tool, arguments: tool_call.arguments)
          # Observe cancellation/reconciliation immediately before crossing the
          # external-effect boundary. Calls already sent cannot be recalled.
          turn.store.atomic { true }
          if turn.background? && subagent?(tool)
            return delegate(tool, tool_call, context)
          end
          value = call_tool(tool, tool_call.arguments, context: context)
          return :waiting if value == :waiting && tool == WaitTool
          normalize_payload(value)
        rescue LostClaim
          raise
        rescue BudgetError => error
          finish_error(execution, tool_call, error.message, details: { "class" => error.class.name, "budget_denied" => true })
          raise
        rescue AuthorizationError => error
          return finish_error(execution, tool_call, error.message, details: { "class" => error.class.name, "authorization_denied" => true })
        rescue StandardError => error
          raise if turn.background? && !error.is_a?(ToolError)
          return finish_error(execution, tool_call, error.message, details: { "class" => error.class.name })
        end
        finish_success(execution, tool_call, payload)
      end

      def create_execution(tool_call)
        turn.store.create_tool_execution(
          "turn_id" => turn.id,
          "tool_call_id" => tool_call.id,
          "tool_name" => tool_call.name,
          "status" => turn.background? && (subagent?(tool_for(tool_call.name)) || [WaitTool, LaunchAgentTool, SendMessageTool].include?(tool_for(tool_call.name))) ? "pending" : "running",
          "arguments" => tool_call.arguments,
          "started_at" => Clock.now
        )
      end

      def finish_success(execution, tool_call, payload)
        json = payload.to_json
        attrs = turn.store.atomic do
          row = turn.store.claim_tool_execution(execution.id, from: execution.status, to: "completed", result: payload, completed_at: Clock.now)
          append_result_once(execution, tool_call, payload) if row
          row
        end
        return superseded_execution(execution) unless attrs
        turn.emit("tool_call.completed", id: tool_call.id, name: tool_call.name, result_chars: json.length)
        ToolExecution.new(attrs)
      end

      def finish_error(execution, tool_call, message, details: nil)
        error = { "message" => message.to_s, "details" => details }.compact
        json = error.to_json
        attrs = turn.store.atomic do
          row = turn.store.claim_tool_execution(execution.id, from: execution.status, to: "failed", error: error, completed_at: Clock.now)
          append_result_once(execution, tool_call, error, error: true) if row
          row
        end
        return superseded_execution(execution) unless attrs
        turn.emit("tool_call.failed", id: tool_call.id, name: tool_call.name, error: error, result_chars: json.length)
        ToolExecution.new(attrs)
      end

      # The execution was reconciled (interrupted) while the tool ran; a
      # synthetic result message already exists, so the late result is dropped.
      def superseded_execution(execution)
        ToolExecution.new(turn.store.load_tool_execution(execution.id))
      end

      def append_result_once(execution, tool_call, payload, error: false)
        return if @defer_result
        return if turn.store.list_messages(turn.conversation.id).any? { |row| row["tool_execution_id"] == execution.id }

        message = turn.conversation.append_message(
          role: "tool",
          kind: "tool_result",
          content: [ { "type" => "tool_result", "tool_call_id" => tool_call.id, "text" => payload.to_json, "error" => error } ],
          turn_id: turn.id,
          tool_execution_id: execution.id,
          metadata: { "tool_name" => tool_call.name }
        )
        turn.emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def skip_remaining(calls, terminal:)
        calls.each do |call|
          turn.store.atomic do
            next if turn.store.list_tool_executions(turn_id: turn.id).any? { |row| row["tool_call_id"] == call.id }
            payload = { "skipped" => true, "message" => "not executed: turn ended by #{terminal.name}" }
            execution = ToolExecution.new(create_execution(call))
            attrs = turn.store.claim_tool_execution(execution.id, from: execution.status, to: "cancelled", result: payload, completed_at: Clock.now)
            append_result_once(ToolExecution.new(attrs), call, payload)
            turn.emit("tool_call.skipped", id: call.id, name: call.name)
          end
        end
      end

      def subagent?(tool)
        tool.is_a?(Class) && tool < SubAgentTool
      end

      def delegate(tool, call, context)
        arguments = tool.validate_arguments(call.arguments)
        Authorization.authorize!(:launch_agent, principal: context.principal, turn: turn, agent: tool.agent, arguments: arguments)
        TurnKit.resolve_agent(tool.agent.name)
        child = turn.store.atomic_graph do
          turn.store.atomic(Background.root_conversation(turn.store, turn.store.load_turn(turn.id))) do
            row = turn.store.list_turns(root_turn_id: turn.root_turn_id).find { |candidate| candidate["parent_tool_execution_id"] == context.execution.id }
            unless row
              built = tool.build_child(task: arguments.fetch("task"), context: context)
              row = turn.store.update_turn(built.id, submitted_at: Clock.now)
            end
            Background.wait(turn, [row.fetch("id")])
            row
          end
        end
        unless Background::TERMINAL.include?(child["status"])
          Background.enqueue(child.fetch("id")) if child["status"] == "pending"
          return :waiting
        end
        finish_success(context.execution, call, SubAgentTool.result(child))
      end

      def tool_for(name)
        turn.agent.effective_tools(turn: turn).find { |tool| tool.tool_name == name.to_s }
      end

      def call_tool(tool, arguments, context:)
        if tool.is_a?(Class)
          tool.call(arguments, context: context)
        else
          tool.class.invoke(tool, arguments, context: context)
        end
      end

      def normalize_payload(value)
        case value
        when Hash then value.transform_keys(&:to_s)
        when Array then { "items" => value }
        else { "result" => value.to_s }
        end
      end
  end
end
