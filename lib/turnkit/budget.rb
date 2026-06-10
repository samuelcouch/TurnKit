# frozen_string_literal: true

module TurnKit
  class Budget
    attr_reader :root_started_at, :max_iterations, :timeout, :max_depth, :max_tool_executions, :max_tool_executions_by_name, :cost_limit

    def initialize(max_iterations:, timeout:, max_depth:, max_tool_executions:, max_tool_executions_by_name: {}, cost_limit: nil, root_started_at: Clock.now)
      @root_started_at = root_started_at
      @max_iterations = max_iterations
      @timeout = timeout
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      @max_tool_executions_by_name = normalize_tool_limits(max_tool_executions_by_name)
      @cost_limit = cost_limit
      @iterations = 0
      @tool_executions = 0
      @tool_executions_by_name = Hash.new(0)
      @cost = 0
      @mutex = Mutex.new
    end

    def count_iteration!
      @mutex.synchronize do
        raise BudgetError, "maximum iterations reached" if max_iterations && @iterations >= max_iterations

        @iterations += 1
      end
    end

    def count_tool_execution!(name = nil)
      @mutex.synchronize do
        key = name.to_s if name
        limit = max_tool_executions_by_name[key] if key
        raise BudgetError, "maximum tool executions reached" if max_tool_executions && @tool_executions >= max_tool_executions
        raise BudgetError, "maximum executions reached for tool #{key}" if limit && @tool_executions_by_name[key] >= limit

        @tool_executions += 1
        @tool_executions_by_name[key] += 1 if key
      end
    end

    def add_usage!(usage)
      add_cost!(usage&.cost)
    end

    def add_cost!(cost)
      return unless cost && cost_limit

      @mutex.synchronize do
        @cost += cost.to_f
        raise BudgetError, "cost limit reached" if @cost > cost_limit
      end
    end

    def check!(depth:)
      raise BudgetError, "maximum sub-agent depth reached" if max_depth && depth > max_depth
      raise BudgetError, "turn timed out" if timeout && Clock.now >= root_started_at + timeout
    end

    private
      def normalize_tool_limits(value)
        value.to_h.transform_keys(&:to_s).transform_values do |limit|
          limit.nil? ? nil : Integer(limit)
        end
      end
  end
end
