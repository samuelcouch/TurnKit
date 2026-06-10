# frozen_string_literal: true

module TurnKit
  class Budget
    attr_reader :root_started_at, :max_iterations, :timeout, :max_depth, :max_tool_executions, :max_tool_executions_by_name, :max_spend

    def self.resume(store:, root_turn_id:, limits: {})
      turns = store.list_turns(root_turn_id: root_turn_id)
      root = turns.find { |turn| turn.fetch("id") == root_turn_id } || turns.first || {}
      budget = new(**limits.merge(root_started_at: root["started_at"] || Clock.now))
      budget.seed!(turns: turns, tool_executions: turns.flat_map { |turn| store.list_tool_executions(turn_id: turn.fetch("id")) })
      budget
    end

    def initialize(max_iterations:, timeout:, max_depth:, max_tool_executions:, max_tool_executions_by_name: {}, max_spend: nil, root_started_at: Clock.now)
      @root_started_at = root_started_at
      @max_iterations = max_iterations
      @timeout = timeout
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      @max_tool_executions_by_name = normalize_tool_limits(max_tool_executions_by_name)
      @max_spend = max_spend
      @iterations = 0
      @tool_executions = 0
      @tool_executions_by_name = Hash.new(0)
      @cost = 0
      @mutex = Mutex.new
    end

    def seed!(turns:, tool_executions:)
      @mutex.synchronize do
        @iterations = Array(turns).sum { |turn| (turn["options"] || {})["iterations"].to_i }
        completed = Array(tool_executions).select { |execution| %w[completed failed].include?(execution["status"]) && !execution.dig("error", "details", "budget_denied") }
        @tool_executions = completed.length
        completed.each { |execution| @tool_executions_by_name[execution.fetch("tool_name").to_s] += 1 }
        @cost = Array(turns).sum { |turn| turn["cost"].to_f }
      end
      self
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
      return unless cost && max_spend

      @mutex.synchronize do
        @cost += cost.to_f
        raise BudgetError, "cost limit reached" if @cost > max_spend
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
