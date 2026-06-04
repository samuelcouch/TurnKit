# frozen_string_literal: true

module TurnKit
  class Agent
    attr_reader :name, :description, :model, :instructions, :tools, :skills, :sub_agents
    attr_reader :client, :store, :max_iterations, :timeout, :cost_limit, :max_depth, :max_tool_executions

    def initialize(name:, description: "", model: nil, instructions: "", tools: [], skills: [], sub_agents: [], client: nil, store: nil,
      max_iterations: nil, timeout: nil, cost_limit: nil, max_depth: nil, max_tool_executions: nil)
      @name = name.to_s
      @description = description.to_s
      @model = model
      @instructions = instructions.to_s
      @tools = Array(tools)
      @skills = Array(skills)
      @sub_agents = Array(sub_agents)
      @client = client
      @store = store
      @max_iterations = max_iterations
      @timeout = timeout
      @cost_limit = cost_limit
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      raise ArgumentError, "name is required" if @name.empty?
    end

    def conversation(model: nil, subject: nil, metadata: {})
      store = effective_store
      record = store.create_conversation(
        "agent_name" => name,
        "model" => model || effective_model,
        "subject" => subject,
        "metadata" => metadata
      )
      Conversation.new(agent: self, record: record, store: store, model: model || effective_model, subject: subject, metadata: metadata)
    end

    def effective_model
      model || TurnKit.default_model
    end

    def effective_client
      client || TurnKit.client
    end

    def effective_store
      store || TurnKit.store
    end

    def effective_tools
      tools + sub_agents.map { |agent| SubAgentTool.for(agent) }
    end

    def build_budget(root_started_at: Clock.now)
      Budget.new(
        max_iterations: max_iterations || TurnKit.max_iterations,
        timeout: timeout || TurnKit.timeout,
        max_depth: max_depth || TurnKit.max_depth,
        max_tool_executions: max_tool_executions || TurnKit.max_tool_executions,
        cost_limit: cost_limit || TurnKit.cost_limit,
        root_started_at: root_started_at
      )
    end

    def instructions_with_skills
      parts = [ instructions ]
      skills.each do |skill|
        parts << "## Skill: #{skill.name}\n\n#{skill.content}"
      end
      parts.reject(&:empty?).join("\n\n")
    end
  end
end
