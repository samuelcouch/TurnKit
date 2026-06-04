# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/pride"

require "turnkit"

class Minitest::Test
  def setup
    TurnKit.store = TurnKit::MemoryStore.new
    TurnKit.client = nil
    TurnKit.default_model = "test-model"
    TurnKit.max_iterations = 25
    TurnKit.max_depth = 3
    TurnKit.max_tool_executions = 100
    TurnKit.timeout = 300
    TurnKit.cost_limit = nil
  end
end

class FakeClient < TurnKit::Client
  attr_reader :calls

  def initialize(*results)
    @results = results.flatten
    @calls = []
  end

  def chat(model:, messages:, tools:, instructions:, temperature: nil, metadata: nil)
    @calls << { model: model, messages: messages, tools: tools, instructions: instructions, metadata: metadata }
    @results.shift || TurnKit::Result.new(text: "done", model: model)
  end
end
