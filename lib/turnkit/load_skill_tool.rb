# frozen_string_literal: true

module TurnKit
  class LoadSkillTool < Tool
    tool_name "load_skill"
    description "Load the full instructions for an available skill by key."
    parameter :key, :string, required: true, description: "Skill key from <skills_available>."

    def self.for(skills)
      Class.new(self) do
        tool_name "load_skill"
        @skills = Array(skills).to_h { |skill| [ skill.key, skill ] }
        class << self
          attr_reader :skills
        end
      end
    end

    def call(key:, context:)
      skill = self.class.skills[key]
      unless skill
        available = self.class.skills.keys.join(", ")
        raise ToolError, "unknown skill: #{key}. Available: #{available}"
      end

      { "key" => skill.key, "name" => skill.name, "content" => skill.content }
    end
  end
end
