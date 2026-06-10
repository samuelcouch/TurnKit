# frozen_string_literal: true

module TurnKit
  class Agent
    attr_reader :name, :description, :model, :instructions, :tools, :skills, :available_skills, :sub_agents
    attr_reader :client, :store, :max_iterations, :timeout, :max_spend, :max_depth, :max_tool_executions, :max_tool_executions_by_name
    attr_reader :prompt_sections, :system_prompt, :prompt_mode, :thinking, :compaction, :output_schema, :input_schema, :on_event
    attr_reader :output_policy, :output_policy_mode, :output_policy_model, :output_retries

    def initialize(name:, description: "", model: nil, instructions: "", tools: [], skills: [], available_skills: [], sub_agents: [],
      system_prompt: nil, prompt_sections: nil, prompt_mode: nil, client: nil, store: nil,
      max_iterations: nil, timeout: nil, max_spend: nil, max_depth: nil, max_tool_executions: nil, max_tool_executions_by_name: nil, thinking: nil, compaction: nil,
      output_schema: nil, input_schema: nil, output_policy: nil, output_policy_mode: nil, output_policy_model: nil, output_policy_thinking: nil, output_retries: 0, on_event: nil)
      @name = name.to_s
      @description = description.to_s
      @model = model
      @instructions = instructions.to_s
      @tools = Array(tools)
      @skills = Array(skills)
      @available_skills = Array(available_skills)
      @sub_agents = Array(sub_agents)
      @system_prompt = system_prompt
      @prompt_sections = prompt_sections
      @prompt_mode = prompt_mode&.to_sym
      @client = client
      @store = store
      @max_iterations = max_iterations
      @timeout = timeout
      @max_spend = max_spend
      @max_depth = max_depth
      @max_tool_executions = max_tool_executions
      @max_tool_executions_by_name = max_tool_executions_by_name
      @thinking = self.class.normalize_thinking(thinking)
      @compaction = compaction
      @output_schema = output_schema
      @input_schema = input_schema
      @output_policy_model = output_policy_model
      @output_policy = normalize_output_policy(output_policy, model: output_policy_model, thinking: output_policy_thinking)
      @output_policy_mode = normalize_output_policy_mode(output_policy_mode)
      @output_retries = Integer(output_retries || 0)
      @on_event = on_event
      raise ArgumentError, "name is required" if @name.empty?
      validate_tools!
    end

    def self.normalize_thinking(value)
      return nil if value.nil?

      attrs = value.respond_to?(:to_h) ? value.to_h : value
      raise ArgumentError, "thinking must be a hash" unless attrs.is_a?(Hash)

      attrs = attrs.transform_keys(&:to_sym)
      unknown = attrs.keys - %i[effort budget]
      raise ArgumentError, "unknown thinking attributes: #{unknown.join(", ")}" if unknown.any?
      raise ArgumentError, "thinking requires :effort or :budget" if attrs[:effort].nil? && attrs[:budget].nil?
      raise ArgumentError, "thinking budget must be an Integer" if attrs[:budget] && !attrs[:budget].is_a?(Integer)

      attrs.slice(:effort, :budget).compact
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

    def run(prompt = nil, task: nil, input: nil, async: false, subject: nil, metadata: {}, parent_run: nil, root_turn_id: nil, prompt_mode: :task, **options)
      task = task || prompt
      raise ArgumentError, "task is required" if task.to_s.empty?
      SchemaCheck.validate!(input, input_schema, error_class: InputError, label: "input") if input_schema

      conversation = self.conversation(subject: subject, metadata: metadata)
      message = conversation.say(task_message(task, input), metadata: { "source" => "application", "task" => true })
      turn = conversation.build_turn(
        trigger_message_id: message.id,
        root_turn_id: root_turn_id || parent_run_root_turn_id(parent_run),
        prompt_mode: prompt_mode,
        **options
      )
      run = Run.new(turn)
      async ? run : run.run!
    end

    def cost
      Cost.from_records(effective_store.list_turns(agent_name: name))
    end

    def usage
      Usage.from_records(effective_store.list_turns(agent_name: name))
    end

    def effective_model
      model || TurnKit.default_model
    end

    def effective_thinking
      thinking
    end

    def effective_output_policy
      Array(output_policy).compact
    end

    def effective_client
      client || TurnKit.client
    end

    def effective_store
      store || TurnKit.store
    end

    def effective_tools
      configured = tools + sub_agents.map { |agent| SubAgentTool.for(agent) }
      skills = effective_available_skills
      skills.empty? ? configured : configured + [ LoadSkillTool.for(skills) ]
    end

    def effective_on_event
      on_event || TurnKit.on_event
    end

    def effective_available_skills
      (Array(TurnKit.available_skills) + available_skills).uniq { |skill| skill.key }
    end

    def effective_prompt_sections
      prompt_sections || TurnKit.prompt_sections
    end

    def effective_prompt_mode(turn: nil)
      return prompt_mode if prompt_mode

      turn&.depth.to_i.positive? ? :minimal : :full
    end

    def system_prompt_for(turn:, conversation:)
      prompt = SystemPrompt.new(agent: self, turn: turn, conversation: conversation, mode: effective_prompt_mode(turn: turn))

      case system_prompt
      when nil
        prompt.to_s
      when String
        system_prompt
      else
        system_prompt.call(prompt).to_s
      end
    end

    def build_budget(root_started_at: Clock.now)
      Budget.new(
        max_iterations: max_iterations || TurnKit.max_iterations,
        timeout: timeout || TurnKit.timeout,
        max_depth: max_depth || TurnKit.max_depth,
        max_tool_executions: max_tool_executions || TurnKit.max_tool_executions,
        max_tool_executions_by_name: max_tool_executions_by_name || TurnKit.max_tool_executions_by_name,
        max_spend: max_spend || TurnKit.max_spend,
        root_started_at: root_started_at
      )
    end

    def instructions_with_skills
      parts = [ instructions ]
      parts << SystemPrompt.loaded_skills_text(skills)
      parts.reject(&:empty?).join("\n\n")
    end

    private
      def validate_tools!
        effective_tools.each do |tool|
          next if tool.is_a?(Class) && tool < Tool
          next if tool.is_a?(Tool)

          raise ArgumentError, "tools must be TurnKit::Tool classes or instances"
        end

        names = effective_tools.map(&:tool_name)
        duplicate = names.find { |name| names.count(name) > 1 }
        raise ArgumentError, "duplicate tool name: #{duplicate}" if duplicate

        effective_tools.each(&:validate_definition!)
      end

      def normalize_output_policy(value, model: nil, thinking: nil)
        case value
        when nil
          nil
        when Array
          value.map { |item| normalize_output_policy(item, model: model, thinking: thinking) }.compact
        when String
          output_policy_from_path(value, model: model, thinking: thinking)
        when Pathname
          output_policy_from_path(value.to_s, model: model, thinking: thinking)
        when Skill
          OutputPolicy.from_skill(value, model: model || TurnKit.output_policy_model, thinking: thinking || TurnKit.output_policy_thinking)
        else
          return value if value.respond_to?(:call) || value.respond_to?(:check)

          raise ArgumentError, "output_policy must be a policy file path, a skill, a #call/#check object, or an array of those"
        end
      end

      def output_policy_from_path(path, model: nil, thinking: nil)
        unless path.match?(/\.(md|markdown|txt)\z/i)
          raise ArgumentError, "output_policy string must be a .md, .markdown, or .txt file path"
        end

        TurnKit::OutputPolicy.from_file(
          path,
          model: model || TurnKit.output_policy_model,
          thinking: thinking || TurnKit.output_policy_thinking
        )
      end

      def normalize_output_policy_mode(value)
        value ||= :fail
        mode = value.to_sym
        raise ArgumentError, "unknown output_policy_mode: #{value}" unless %i[report fail].include?(mode)

        mode
      end

      def task_message(task, input)
        text = task.to_s
        return text if input.nil?

        "Task:\n#{text}\n\nInput:\n#{format_task_input(input)}"
      end

      def format_task_input(input)
        case input
        when String
          input
        else
          JSON.pretty_generate(input)
        end
      rescue JSON::GeneratorError
        input.inspect
      end

      def parent_run_root_turn_id(parent_run)
        return nil unless parent_run
        return parent_run.root_turn_id if parent_run.respond_to?(:root_turn_id)
        return parent_run.fetch("root_turn_id") if parent_run.respond_to?(:fetch)

        nil
      end
  end
end
