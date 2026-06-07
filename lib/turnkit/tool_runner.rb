# frozen_string_literal: true

module TurnKit
  class ToolRunner
    def initialize(turn)
      @turn = turn
    end

    def dispatch(tool_calls)
      tool_calls.each do |tool_call|
        execution = run(tool_call)
        return execution if execution.completed? && tool_class(tool_call.name)&.ends_turn?
      end
      nil
    end

    def completion_message(execution)
      tool = tool_class(execution.tool_name)
      tool.completion_message(execution.result) || execution.result&.fetch("result", nil) || "Completed via #{execution.tool_name}."
    end

    private
      attr_reader :turn

      def run(tool_call)
        turn.budget.count_tool_execution!
        tool = tool_class(tool_call.name)
        execution = ToolExecution.new(create_execution(tool_call))

        unless tool
          return finish_error(execution, tool_call, "unknown tool: #{tool_call.name}")
        end

        if tool_call.arguments_error
          return finish_error(execution, tool_call, tool_call.arguments_error)
        end

        context = ToolContext.new(turn: turn, execution: execution)
        payload = begin
          normalize_payload(tool.call(tool_call.arguments, context: context))
        rescue StandardError => error
          return finish_error(execution, tool_call, error.message, details: { "class" => error.class.name })
        end
        finish_success(execution, tool_call, payload)
      end

      def create_execution(tool_call)
        turn.store.create_tool_execution(
          "turn_id" => turn.id,
          "tool_call_id" => tool_call.id,
          "tool_name" => tool_call.name,
          "status" => "running",
          "arguments" => tool_call.arguments,
          "started_at" => Clock.now
        )
      end

      def finish_success(execution, tool_call, payload)
        attrs = turn.store.update_tool_execution(execution.id, "status" => "completed", "result" => payload, "completed_at" => Clock.now)
        append_result(execution, tool_call, payload)
        turn.emit("tool_call.completed", id: tool_call.id, name: tool_call.name)
        ToolExecution.new(attrs)
      end

      def finish_error(execution, tool_call, message, details: nil)
        error = { "message" => message.to_s, "details" => details }.compact
        attrs = turn.store.update_tool_execution(execution.id, "status" => "failed", "error" => error, "completed_at" => Clock.now)
        append_result(execution, tool_call, error)
        turn.emit("tool_call.failed", id: tool_call.id, name: tool_call.name, error: error)
        ToolExecution.new(attrs)
      end

      def append_result(execution, tool_call, payload)
        message = turn.conversation.append_message(
          role: "tool",
          kind: "tool_result",
          text: payload.to_json,
          turn_id: turn.id,
          tool_execution_id: execution.id,
          metadata: { "tool_call_id" => tool_call.id, "tool_name" => tool_call.name }
        )
        turn.emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def tool_class(name)
        turn.agent.effective_tools.find { |tool| tool.tool_name == name.to_s }
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
