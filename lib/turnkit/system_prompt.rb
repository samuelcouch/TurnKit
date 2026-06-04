# frozen_string_literal: true

module TurnKit
  class SystemPrompt
    DEFAULT_SECTIONS = %i[agent instructions behavior loaded_skills available_skills tools subject environment].freeze
    SECTION_METHODS = {
      agent: :agent_section,
      instructions: :instructions_section,
      behavior: :behavior_section,
      loaded_skills: :loaded_skills_section,
      available_skills: :available_skills_section,
      tools: :tools_section,
      subject: :subject_section,
      environment: :environment_section
    }.freeze

    DEFAULT_BEHAVIOR = <<~TEXT.strip
      Treat each user message as a constraint on the current task. Follow the
      agent instructions and loaded skills first, then use tools when they are
      available and needed.

      Use the provided environment as the source of truth for the current date
      and time. Do not guess relative dates like "today", "tomorrow", or
      "yesterday" when the environment gives an exact calendar anchor.

      Only use tools listed in <tools_available>. If a tool you want is not
      listed, it is unavailable for this turn; adjust your answer instead of
      pretending to call it.

      If a tool returns an error, read the error and fix your inputs before
      trying again. Do not retry the identical failing call blindly.

      Report outcomes honestly. If you cannot verify something, say so or omit
      the claim instead of inventing details.
    TEXT

    attr_reader :agent, :turn, :conversation, :sections

    def initialize(agent:, turn:, conversation:, sections: nil)
      @agent = agent
      @turn = turn
      @conversation = conversation
      @sections = Array(sections || agent.effective_prompt_sections)
    end

    def to_s
      sections.map { |section| render(section) }.compact.reject { |value| value.strip.empty? }.join("\n\n")
    end

    def render(section)
      method = SECTION_METHODS[section.to_sym]
      raise ArgumentError, "unknown prompt section: #{section}" unless method

      public_send(method)
    end

    def agent_section
      lines = [
        "- Name: #{agent.name}",
        agent.description.empty? ? nil : "- Description: #{agent.description}",
        "- Model: #{turn.model || agent.effective_model}"
      ].compact

      tagged("agent", lines.join("\n"))
    end

    def instructions_section
      return nil if agent.instructions.empty?

      tagged("instructions", agent.instructions)
    end

    def behavior_section
      tagged("behavior", TurnKit.prompt_behavior || DEFAULT_BEHAVIOR)
    end

    def loaded_skills_section
      return nil if agent.skills.empty?

      tagged(
        "skills_loaded",
        self.class.loaded_skills_text(agent.skills)
      )
    end

    def self.loaded_skills_text(skills)
      skills.map { |skill| "## Skill: #{skill.key}\n\n#{skill.content}" }.join("\n\n")
    end

    def available_skills_section
      skills = agent.effective_available_skills
      return nil if skills.empty?

      entries = skills.map do |skill|
        description = skill.description.empty? ? nil : " — #{skill.description}"
        "- #{skill.key}: #{skill.name}#{description}"
      end

      tagged(
        "skills_available",
        "Load or follow a skill when the task matches its description.\n\n#{entries.join("\n")}"
      )
    end

    def tools_section
      tools = agent.effective_tools

      if tools.empty?
        tagged("tools_available", "(none)\n\nNo tools are available for this turn.")
      else
        tagged("tools_available", tools.map { |tool| tool_line(tool) }.join("\n"))
      end
    end

    def subject_section
      return nil unless conversation.subject&.respond_to?(:to_prompt)

      value = conversation.subject.to_prompt.to_s.strip
      return nil if value.empty?

      tagged("subject_context", value)
    end

    def environment_section
      anchor = turn.started_at || Clock.now
      today = anchor.to_date
      yesterday = today - 1
      tomorrow = today + 1

      tagged(
        "environment",
        [
          "- Today: #{today.strftime('%A, %B %-d, %Y')} (#{today.iso8601})",
          "- Current time: #{anchor.strftime('%-I:%M %Z')}",
          "- Yesterday: #{yesterday.strftime('%A, %B %-d, %Y')} (#{yesterday.iso8601})",
          "- Tomorrow: #{tomorrow.strftime('%A, %B %-d, %Y')} (#{tomorrow.iso8601})"
        ].join("\n")
      )
    end

    private
      def tagged(name, content)
        "<#{name}>\n#{content}\n</#{name}>"
      end

      def tool_line(tool)
        description = tool.description.empty? ? nil : ": #{tool.description}"
        params = tool.parameters.map do |param|
          required = param.fetch(:required) ? " required" : ""
          enum = param[:enum] ? " enum=#{Array(param[:enum]).join('|')}" : ""
          "#{param.fetch(:name)}(#{param.fetch(:type)}#{required}#{enum})"
        end
        suffix = params.empty? ? "" : " Parameters: #{params.join(', ')}."
        terminal = tool.ends_turn? ? " Ends the turn." : ""
        "- #{tool.tool_name}#{description}#{suffix}#{terminal}"
      end
  end
end
