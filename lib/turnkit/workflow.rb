# frozen_string_literal: true

require_relative "agent"

module TurnKit
  class Workflow
    ORCHESTRATOR_PREAMBLE = <<~TEXT.strip
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

    DEFAULT_INSTRUCTIONS = ORCHESTRATOR_PREAMBLE

    attr_reader :name, :options

    def initialize(name: "workflow", instructions: nil, preamble: true, **options)
      @name = name.to_s
      raise ArgumentError, "name is required" if @name.empty?

      @options = options.merge(
        name: @name,
        prompt_mode: options.fetch(:prompt_mode, :task),
        instructions: compose_instructions(instructions, preamble: preamble)
      ).freeze
      @agent = Agent.new(**@options)
    end

    def run(prompt = nil, task: nil, input: nil, async: false, subject: nil, metadata: {}, **overrides)
      agent(**overrides).run(task || prompt, input: input, async: async, subject: subject, metadata: metadata)
    end

    def agent(**overrides)
      overrides.empty? ? @agent : Agent.new(**@options.merge(overrides.compact))
    end

    private
      def compose_instructions(instructions, preamble:)
        parts = []
        parts << ORCHESTRATOR_PREAMBLE if preamble
        parts << instructions.to_s.strip unless instructions.to_s.strip.empty?
        parts.join("\n\n")
      end
  end
end
