# frozen_string_literal: true

module TurnKit
  class Result
    attr_reader :text, :tool_calls, :usage, :model, :finish_reason

    def initialize(text: "", tool_calls: [], usage: Usage.new, model: nil, finish_reason: nil)
      @text = text.to_s
      @tool_calls = Array(tool_calls)
      @usage = usage || Usage.new
      @model = model
      @finish_reason = finish_reason
    end

    def tool_calls?
      tool_calls.any?
    end
  end
end
