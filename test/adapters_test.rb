# frozen_string_literal: true

require_relative "test_helper"

class AdaptersTest < Minitest::Test
  def test_ruby_llm_provider_errors_are_turnkit_task_failures
    require "ruby_llm"
    adapter = TurnKit::Adapters::RubyLLM.new
    original_chat, original_paint = RubyLLM.method(:chat), RubyLLM.method(:paint)
    rejected = ->(*, **) { raise RubyLLM::BadRequestError, "invalid request" }
    RubyLLM.define_singleton_method(:chat, rejected)
    RubyLLM.define_singleton_method(:paint, rejected)
    error = assert_raises(TurnKit::ModelError) do
      adapter.chat(model: "gpt-4.1-mini", messages: [], tools: [], instructions: "")
    end
    assert_instance_of RubyLLM::BadRequestError, error.cause
    assert_includes error.message, "invalid request"
    assert_raises(TurnKit::ModelError) do
      adapter.view_media(model: "gemini-2.5-flash", media: TurnKit::MediaInput.bytes("image", mime_type: "image/png", filename: "image.png"), objective: "describe")
    end
    assert_raises(TurnKit::ModelError) { adapter.paint(model: "gpt-image-2", prompt: "image") }
    RubyLLM.define_singleton_method(:chat) { |**| raise RubyLLM::ModelNotFoundError, "unknown model" }
    assert_raises(TurnKit::ModelError) do
      adapter.chat(model: "unknown", messages: [], tools: [], instructions: "")
    end
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat) if original_chat
    RubyLLM.define_singleton_method(:paint, original_paint) if original_paint
  end

  def test_ruby_llm_adapter_normalizes_output_schema_for_strict_providers
    schema = {
      type: "object",
      properties: {
        title: { type: "string" },
        meta: { type: "object", properties: { count: { type: "integer" } } }
      },
      required: ["title", "meta"]
    }

    normalized = TurnKit::Adapters::RubyLLM.new.send(:normalize_schema, schema)

    assert_equal false, normalized.fetch("additionalProperties")
    assert_equal false, normalized.fetch("properties").fetch("meta").fetch("additionalProperties")
    assert_equal "string", normalized.fetch("properties").fetch("title").fetch("type")
  end
  def test_ruby_llm_private_provider_completion_canary
    require "ruby_llm"

    # TurnKit::Adapters::RubyLLM#complete_without_tool_execution depends on
    # this private RubyLLM API. If this test fails after a ruby_llm upgrade,
    # update the adapter.
    assert ::RubyLLM::Chat.private_method_defined?(:provider_completion),
      "RubyLLM::Chat#provider_completion is gone; update TurnKit::Adapters::RubyLLM#complete_without_tool_execution"
  end
  def test_ruby_llm_adapter_does_not_execute_turnkit_tools
    require "ruby_llm"

    tool_class = TurnKit::Adapters::RubyLLM.new.send(:ruby_llm_tool, ContextCheckingTool)

    error = assert_raises(TurnKit::ToolError) do
      tool_class.new.execute
    end
    assert_includes error.message, "tools must be executed by TurnKit turns"
  end
  def test_codex_adapter_supports_structured_output_schema
    schema = {
      type: "object",
      properties: { verdict: { type: "string" } },
      required: [ "verdict" ],
      additionalProperties: false
    }
    runner = lambda do |command, stdin_data:, chdir:|
      schema_path = command[command.index("--output-schema") + 1]
      output_path = command[command.index("-o") + 1]
      assert_equal JSON.parse(JSON.generate(schema)), JSON.parse(File.read(schema_path))
      File.write(output_path, { verdict: "ok" }.to_json)
      [ "", "", TurnKit::Adapters::Codex::Status.new(successful: true) ]
    end
    adapter = TurnKit::Adapters::Codex.new(runner: runner)

    result = adapter.chat(model: "codex", messages: [ { role: "user", content: "Review" } ], tools: [], instructions: "", output_schema: schema)

    assert_equal({ "verdict" => "ok" }, result.output_data)
  end
  def test_codex_adapter_rejects_turnkit_tools
    adapter = TurnKit::Adapters::Codex.new(runner: ->(*) { raise "should not run" })

    error = assert_raises(TurnKit::ToolError) do
      adapter.chat(model: "codex", messages: [], tools: [ ContextCheckingTool ], instructions: "")
    end
    assert_includes error.message, "TurnKit tools are not supported"
  end
  def test_ruby_llm_adapter_configures_provider_keys_from_environment
    require "ruby_llm"

    original_openai_key = RubyLLM.config.openai_api_key
    original_gemini_key = RubyLLM.config.gemini_api_key
    original_env_openai_key = ENV["OPENAI_API_KEY"]
    original_env_gemini_key = ENV["GEMINI_API_KEY"]
    RubyLLM.config.openai_api_key = nil
    RubyLLM.config.gemini_api_key = nil
    ENV["OPENAI_API_KEY"] = "openai-test-key"
    ENV["GEMINI_API_KEY"] = "gemini-test-key"

    TurnKit::Adapters::RubyLLM.new.send(:configure_from_environment)

    assert_equal "openai-test-key", RubyLLM.config.openai_api_key
    assert_equal "gemini-test-key", RubyLLM.config.gemini_api_key
  ensure
    RubyLLM.config.openai_api_key = original_openai_key if defined?(RubyLLM)
    RubyLLM.config.gemini_api_key = original_gemini_key if defined?(RubyLLM)
    ENV["OPENAI_API_KEY"] = original_env_openai_key
    ENV["GEMINI_API_KEY"] = original_env_gemini_key
  end
  def test_ruby_llm_adapter_applies_thinking_config
    require "ruby_llm"

    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :thinking

      def with_thinking(**thinking)
        @thinking = RubyLLM::Thinking::Config.new(**thinking)
      end
    end.new

    adapter.send(:apply_thinking, chat, { "effort" => :high, "budget" => 4_000 })

    assert_equal "high", chat.thinking.effort
    assert_equal 4_000, chat.thinking.budget
  end
  def test_ruby_llm_adapter_preserves_tool_messages
    require "ruby_llm"

    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def add_message(attributes)
        @messages << RubyLLM::Message.new(attributes)
      end
    end.new

    adapter.send(:add_message, chat, {
      role: :assistant,
      content: "",
      tool_calls: [ { "id" => "call_1", "name" => "context_checking_tool", "arguments" => { "ok" => true } } ]
    })
    adapter.send(:add_message, chat, { role: :tool, content: "{\"ok\":true}", tool_call_id: "call_1" })

    assistant_message = chat.messages.first
    tool_message = chat.messages.last
    assert assistant_message.tool_call?
    assert_equal "context_checking_tool", assistant_message.tool_calls.fetch("call_1").name
    assert tool_message.tool_result?
    assert_equal "call_1", tool_message.tool_call_id
  end
  def test_ruby_llm_adapter_caches_stable_anthropic_instructions
    require "ruby_llm"

    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def add_message(attributes)
        @messages << RubyLLM::Message.new(attributes)
      end

      def with_instructions(_instructions)
        raise "with_instructions should not be used for cacheable Anthropic prompts"
      end
    end.new
    adapter.send(:add_instructions, chat, "stable", "dynamic", model: "claude-sonnet-4-5")

    assert_equal 2, chat.messages.length
    cached_content = chat.messages.first.content
    assert_instance_of RubyLLM::Content::Raw, cached_content
    assert_equal "stable", cached_content.value.first.fetch(:text)
    assert_equal({ type: "ephemeral" }, cached_content.value.first.fetch(:cache_control))
    assert_equal "dynamic", chat.messages.last.content
  end
  def test_ruby_llm_adapter_skips_cache_for_non_anthropic_models
    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :instructions

      def with_instructions(instructions)
        @instructions = instructions
      end
    end.new
    adapter.send(:add_instructions, chat, "stable", "dynamic", model: "gpt-4.1-mini")

    assert_equal "stable\n\ndynamic", chat.instructions
  end
  def test_ruby_llm_adapter_respects_prompt_cache_off
    TurnKit.prompt_cache = :off
    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :instructions

      def with_instructions(instructions)
        @instructions = instructions
      end
    end.new
    adapter.send(:add_instructions, chat, "stable", "dynamic", model: "claude-sonnet-4-5")

    assert_equal "stable\n\ndynamic", chat.instructions
  end
end
