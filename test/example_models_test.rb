# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/shared/model_registry"
require "open3"

class ExampleModelsTest < Minitest::Test
  def test_tool_examples_use_sol_compatible_defaults_without_clobbering_overrides
    script = <<~'RUBY'
      require "turnkit"
      require_relative "examples/shared/model_registry"
      TurnKitExamples.define_singleton_method(:prepare_model) { |model| model }
      TurnKit::Agent.prepend(Module.new do
        def initialize(**options)
          super
          throw :example_agent, self
        end
      end)
      path, entry = ARGV
      agent = catch(:example_agent) do
        load path
        AmazonMemoWriter.public_send(entry || "workflow") if path.include?("amazon_memo_writer")
      end
      puts JSON.generate(model: agent.effective_model, thinking: agent.effective_thinking)
    RUBY
    examples = %w[amazon_memo_writer bay_alarm_lead_researcher workflow_researcher neighbor_name_researcher technical_explainer]
    cases = examples.flat_map do |name|
      other_default = %w[amazon_memo_writer bay_alarm_lead_researcher].include?(name) ? { "effort" => "medium" } : nil
      [[name, "gpt-5.6-sol", nil, nil, { "effort" => "none" }, nil],
       [name, "claude-sonnet-5", nil, nil, other_default, nil]]
    end
    cases += [
      ["amazon_memo_writer", "gpt-5.6-sol", "high", nil, { "effort" => "high" }, "benchmark"],
      ["bay_alarm_lead_researcher", "gpt-5.6-sol", "high", nil, { "effort" => "high" }, nil],
      ["technical_explainer", "gpt-5.6-sol", "high", nil, { "effort" => "high" }, nil],
      ["technical_explainer", "claude-sonnet-5", nil, "4000", { "budget" => 4000 }, nil]
    ]
    cases.each do |name, model, effort, budget, expected, entry|
      env = { "TURNKIT_MODEL" => model, "TURNKIT_THINKING_EFFORT" => effort, "TURNKIT_THINKING_BUDGET" => budget }
      output, error, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-e", script,
        "examples/#{name}/#{name}.rb", *Array(entry))
      assert status.success?, "#{name}: #{error}"
      result = JSON.parse(output.lines.last)
      assert_equal model, result.fetch("model")
      expected.nil? ? assert_nil(result["thinking"]) : assert_equal(expected, result["thinking"])
    end
  end

  def test_catalog_refresh_is_only_used_for_unknown_models
    registry = Object.new
    calls = []
    registry.define_singleton_method(:find) do |model|
      calls << [:find, model]
      raise RubyLLM::ModelNotFoundError, model if model == "gpt-unavailable"
      raise RubyLLM::ModelNotFoundError, model if model == "gpt-new" && !calls.include?([:refresh, true])
      model
    end
    registry.define_singleton_method(:refresh!) { |remote_only:| calls << [:refresh, remote_only] }
    original_models = RubyLLM.method(:models)
    original_key = ENV["OPENAI_API_KEY"]
    config_keys = %i[openai_api_key anthropic_api_key gemini_api_key openrouter_api_key].to_h { |key| [key, RubyLLM.config.public_send(key)] }
    verbose = $VERBOSE
    $VERBOSE = nil
    RubyLLM.define_singleton_method(:models) { registry }
    ENV["OPENAI_API_KEY"] = "test-key"

    assert_equal "known", TurnKitExamples.prepare_model("known")
    assert_equal [[:find, "known"]], calls
    assert_equal "gpt-new", TurnKitExamples.prepare_model("gpt-new")
    assert_equal [[:find, "known"], [:find, "gpt-new"], [:refresh, true], [:find, "gpt-new"]], calls
    calls.clear
    assert_raises(RubyLLM::ModelNotFoundError) { TurnKitExamples.prepare_model("gpt-unavailable") }
    assert_equal [[:find, "gpt-unavailable"], [:refresh, true], [:find, "gpt-unavailable"]], calls
  ensure
    RubyLLM.define_singleton_method(:models, original_models) if original_models
    ENV["OPENAI_API_KEY"] = original_key
    config_keys&.each { |key, value| RubyLLM.config.public_send("#{key}=", value) }
    $VERBOSE = verbose
  end
end
