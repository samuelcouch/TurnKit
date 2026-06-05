# frozen_string_literal: true

module TechnicalExplainer
  class PromptFiles
    def initialize(root)
      @root = root
    end

    def instructions
      File.read(File.join(@root, "prompts", "instructions.md"))
    end

    def system_prompt(prompt)
      render(File.read(File.join(@root, "prompts", "system_prompt.md")), prompt)
    end

    private
      def render(template, prompt)
        template.gsub(/\{\{([a-z_]+)\}\}/) do
          prompt.section(Regexp.last_match(1).to_sym).to_s
        end
      end
  end
end
