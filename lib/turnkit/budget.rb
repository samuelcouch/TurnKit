# frozen_string_literal: true

module TurnKit
  class Budget
    attr_reader :root_started_at, :max_iterations, :timeout, :max_depth, :max_tool_executions, :cost_limit

    def initialize(max_iterations:, timeout:, max_depth:, max_tool_executions:, cost_limit: nil, root_started_at: Clock.now)
      @root_started_at = root_started_at
      @max_iterations = max_iterations
      @timeout = timeout
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      @cost_limit = cost_limit
      @iterations = 0
      @tool_executions = 0
      @cost = 0
      @mutex = Mutex.new
    end

    def count_iteration!
      @mutex.synchronize do
        @iterations += 1
        raise Error, "maximum iterations reached" if max_iterations && @iterations > max_iterations
      end
    end

    def count_tool_execution!
      @mutex.synchronize do
        @tool_executions += 1
        raise Error, "maximum tool executions reached" if max_tool_executions && @tool_executions > max_tool_executions
      end
    end

    def add_usage!(usage)
      return unless usage&.cost && cost_limit

      @mutex.synchronize do
        @cost += usage.cost.to_f
        raise Error, "cost limit reached" if @cost > cost_limit
      end
    end

    def check!(depth:)
      raise Error, "maximum sub-agent depth reached" if max_depth && depth > max_depth
      raise Error, "turn timed out" if timeout && Clock.now >= root_started_at + timeout
    end
  end
end
