# frozen_string_literal: true

require_relative "agent"

module TurnKit
  class Workflow
    attr_reader :name, :description, :instructions, :tools, :skills, :available_skills
    attr_reader :model, :client, :store, :prompt_mode, :thinking, :compaction, :output_schema
    attr_reader :on_event
    attr_reader :max_iterations, :timeout, :cost_limit, :max_depth, :max_tool_executions, :max_tool_executions_by_name
    attr_reader :output_audit, :output_audit_mode, :output_policy, :output_policy_mode, :output_policy_model, :output_policy_thinking

    DEFAULT_INSTRUCTIONS = <<~TEXT.strip
      You are an autonomous task orchestrator. Navigate from the application
      request to a final output without asking the user follow-up questions.

      Use the available tools to gather context, inspect sources, take actions,
      persist outputs, and verify work. Use loaded skills as reusable workflow
      patterns. Iterate when work needs missing context, critique, revision, or
      verification.

      When multiple independent items need the same kind of fetch or read, and
      an available batch tool can handle them in one call, prefer the batch tool
      over repeated one-item tool calls.

      Stop when the task is complete, when the available context and tools are
      sufficient for the best possible answer, or when further iteration would
      not materially improve the result. Respect runtime, cost, and iteration
      limits.
    TEXT

    def initialize(name: "workflow", description: "", instructions: nil,
      tools: [], skills: [], available_skills: [], model: nil, client: nil,
      store: nil, prompt_mode: :task, thinking: nil, compaction: nil, on_event: nil,
      output_schema: nil, max_iterations: nil, timeout: nil, max_spend: nil,
      cost_limit: nil, max_depth: nil, max_tool_executions: nil, max_tool_executions_by_name: nil,
      output_audit: nil, output_audit_mode: nil, output_policy: nil, output_policy_mode: nil, output_policy_model: nil, output_policy_thinking: nil)

      @name = name.to_s
      @description = description.to_s
      @instructions = instructions || DEFAULT_INSTRUCTIONS
      @tools = Array(tools)
      @skills = Array(skills)
      @available_skills = Array(available_skills)
      @model = model
      @client = client
      @store = store
      @prompt_mode = prompt_mode
      @thinking = thinking
      @compaction = compaction
      @on_event = on_event
      @output_schema = output_schema
      @max_iterations = max_iterations
      @timeout = timeout
      @cost_limit = cost_limit || max_spend
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      @max_tool_executions_by_name = max_tool_executions_by_name
      @output_audit = output_audit
      @output_audit_mode = output_audit_mode
      @output_policy = output_policy
      @output_policy_mode = output_policy_mode
      @output_policy_model = output_policy_model
      @output_policy_thinking = output_policy_thinking
      raise ArgumentError, "name is required" if @name.empty?
      @agent = build_agent
    end

    def run(prompt = nil, task: nil, input: nil, async: false, subject: nil, metadata: {},
      max_spend: nil, cost_limit: nil, **options)

      task = task || prompt
      raise ArgumentError, "task is required" if task.to_s.empty?

      runtime_agent = if options.empty? && cost_limit.nil? && max_spend.nil?
        @agent
      else
        build_agent(cost_limit: cost_limit || max_spend, **options)
      end

      runtime_agent.run(
        task,
        input: input,
        async: async,
        subject: subject,
        metadata: metadata
      )
    end

    def agent(**options)
      options.empty? ? @agent : build_agent(**options)
    end

    def max_spend
      cost_limit
    end

    private
      def build_agent(**overrides)
        attrs = {
          name: name,
          description: description,
          instructions: instructions,
          tools: tools,
          skills: skills,
          available_skills: available_skills,
          model: model,
          client: client,
          store: store,
          prompt_mode: prompt_mode,
          thinking: thinking,
          compaction: compaction,
          on_event: on_event,
          output_schema: output_schema,
          max_iterations: max_iterations,
          timeout: timeout,
          cost_limit: cost_limit,
          max_depth: max_depth,
          max_tool_executions: max_tool_executions,
          max_tool_executions_by_name: max_tool_executions_by_name,
          output_audit: output_audit,
          output_audit_mode: output_audit_mode,
          output_policy: output_policy,
          output_policy_mode: output_policy_mode,
          output_policy_model: output_policy_model,
          output_policy_thinking: output_policy_thinking
        }
        attrs.merge!(overrides.compact)
        Agent.new(**attrs)
      end
  end
end
