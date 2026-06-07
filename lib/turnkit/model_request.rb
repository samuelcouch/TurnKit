# frozen_string_literal: true

module TurnKit
  class ModelRequest
    attr_reader :model, :messages, :tools, :instructions, :thinking, :output_schema, :metadata, :report

    def initialize(model:, messages:, tools:, instructions:, thinking: nil, output_schema: nil, metadata: {}, report: nil)
      @model = model
      @messages = Array(messages)
      @tools = Array(tools)
      @instructions = instructions.to_s
      @thinking = thinking
      @output_schema = output_schema
      @metadata = metadata || {}
      @report = report || {}
    end

    def tool_names
      tools.map(&:tool_name)
    end

    def to_h
      {
        "model" => model,
        "messages" => messages,
        "tools" => tool_names,
        "instructions" => instructions,
        "thinking" => thinking,
        "output_schema" => output_schema,
        "metadata" => metadata,
        "report" => report
      }
    end
  end
end
