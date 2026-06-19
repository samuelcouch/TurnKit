# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/pride"
require "tempfile"

require "turnkit"

class Minitest::Test
  def setup
    TurnKit.store = TurnKit::MemoryStore.new
    TurnKit.client = nil
    TurnKit.default_model = "test-model"
    TurnKit.max_iterations = 25
    TurnKit.max_depth = 3
    TurnKit.max_tool_executions = 100
    TurnKit.max_tool_executions_by_name = {}
    TurnKit.timeout = 300
    TurnKit.max_spend = nil
    TurnKit.cost_rates = {}
    TurnKit.cost_calculator = nil
    TurnKit.prompt_cache = :auto
    TurnKit.compaction = true
    TurnKit.prompt_sections = TurnKit::SystemPrompt::DEFAULT_SECTIONS.dup
    TurnKit.prompt_behavior = nil
    TurnKit.prompt_data_max_chars = 20_000
    TurnKit.available_skills = []
    TurnKit.context_contributors = []
    TurnKit.system_prompt_contributors = []
    TurnKit.model_prompt_contributors = {}
    TurnKit.output_policy_model = nil
    TurnKit.output_policy_thinking = { effort: :low }
  end
end

class FakeClient < TurnKit::Client
  attr_reader :calls

  def initialize(*results)
    @results = results.flatten
    @calls = []
  end

  def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
    @calls << { model: model, messages: messages, tools: tools, instructions: instructions, thinking: thinking, output_schema: output_schema, metadata: metadata, on_event: on_event }
    @results.shift || TurnKit::Result.new(text: "done", model: model)
  end

  def paint(prompt:, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: nil, on_event: nil)
    @calls << { prompt: prompt, model: model, provider: provider, size: size, assume_model_exists: assume_model_exists, input_images: input_images, mask: mask, params: params, metadata: metadata, on_event: on_event }
    @results.shift || TurnKit::Result.new(parts: [ TurnKit::ImageResult.new(model: model, provider: provider&.to_s, metadata: metadata || {}).to_h.merge("type" => "image") ], model: model)
  end

  def view_media(media:, objective:, model:, provider: nil, output_schema: nil, params: {}, metadata: nil, on_event: nil)
    input = TurnKit::MediaInput.wrap(media)
    @calls << { media: media, objective: objective, model: model, provider: provider, output_schema: output_schema, params: params, metadata: metadata, on_event: on_event }
    analysis = TurnKit::MediaAnalysisResult.new(text: "reviewed", model: model, provider: provider&.to_s, media: input.to_h, metadata: metadata || {})
    @results.shift || TurnKit::Result.new(parts: [ analysis.to_h.merge("type" => "media_analysis") ], model: model)
  end
end
