# frozen_string_literal: true

# Shared memory/PostgreSQL tests. Only completions are synthetic; outgoing
# messages are rendered by the installed SDK, including its real native codecs.
module NativeProviderReplay
  class ReplayClient < TurnKit::Adapters::RubyLLM
    attr_reader :payloads
    attr_accessor :before_response

    def initialize(*responses)
      super()
      @responses, @payloads = responses, []
    end

    def complete_without_tool_execution(chat)
      payload = if chat.respond_to?(:render)
        chat.render
      else
        chat.instance_variable_get(:@provider).send(:render_payload, chat.messages, tools: chat.tools,
          temperature: nil, model: chat.model, thinking: chat.instance_variable_get(:@thinking))
      end
      @payloads << JSON.parse(JSON.generate(payload))
      before_response&.call(@payloads.length)
      @responses.shift || raise("unexpected completion")
    end
  end

  def test_native_blocks_survive_pause_reload_and_multistep_tools
    each_native_provider do |provider, model|
      first = native_fixture(provider, model, tools: true)
      final = native_fixture(provider, model, tools: false)
      client = ReplayClient.new(first, final)
      tool = self.class::CountingTool.new
      events = []
      run = register("native_#{provider}", model: model, thinking: { effort: :high },
        client: client, tools: [ContextCheckingTool, tool]).run("research", async: true).perform_later
      TurnKit.on_event = lambda do |event|
        events << event.to_h
        TurnKit.load_turn(run.id).pause! if event.type == "model.completed" && client.payloads.length == 1
      end
      TurnKit::Background.perform(run.id)
      assert run.reload.paused?
      assert_equal 160, run.usage.total_tokens
      stored = TurnKit.load_conversation(run.turn.conversation.id).messages.last
      assert_equal native_blocks(first, provider), stored.content.find { |part| part["type"] == "provider" }.fetch("data")
      TurnKit.load_turn(run.id).resume!
      drain_jobs
      assert run.reload.completed?
      assert_equal "public answer", run.output_text
      assert_equal 1, tool.calls
      assert_native_payload(client.payloads.last, first, provider)
      visible = run.turn.conversation.messages_after(0).map(&:to_h).to_json + events.to_json
      refute_includes visible, "private-fixture"
      refute_includes visible, "opaque-fixture"
      # A later turn must also retain opaque state from the final text response.
      client.before_response = nil
      client.instance_variable_get(:@responses) << final
      run.turn.conversation.ask("followup", async: true).perform_later
      drain_jobs
      assistant = native_messages(client.payloads.last, provider).select { |message| %w[assistant model].include?(message["role"]) }.last
      assert_equal native_blocks(final, provider), assistant.fetch(provider == "gemini" ? "parts" : "content")
    end
  end

  def test_native_stale_proposals_and_recovery_replay_original_blocks
    each_native_provider do |provider, model|
      first = native_fixture(provider, model, tools: true)
      client = ReplayClient.new(first, native_fixture(provider, model, tools: false))
      tool = self.class::CountingTool.new
      run = register("native_recovery_#{provider}", model: model, thinking: { effort: :high },
        client: client, tools: [ContextCheckingTool, tool]).run("research", async: true).perform_later
      client.before_response = lambda do |number|
        run.steer!("revised research", key: "focus") if number == 1
        raise IOError, "synthetic worker loss before response" if number == 2
      end
      assert_raises(IOError) { TurnKit::Background.perform(run.id) }
      receipt = TurnKit.load_turn(run.id).control_state.dig("controls", "inputs").first
      expire(run)
      TurnKit::Background.reconcile
      drain_jobs
      assert run.reload.completed?
      assert_equal 0, tool.calls
      assert_equal %w[cancelled cancelled], run.tool_executions.map(&:status)
      assert_equal client.payloads[1], client.payloads[2]
      assert_native_payload(client.payloads.last, first, provider)
      assert_includes native_messages(client.payloads.last, provider).last.to_json, "revised research"
      assert_equal receipt, run.control_state.dig("controls", "inputs").first
      messages = TurnKit.load_conversation(run.turn.conversation.id).messages_after(0)
      assert_equal 1, messages.count { |message| message.metadata["steering_id"] }
      refute_includes messages.map(&:to_h).to_json, "opaque-fixture"
    end
  end

  private
    def each_native_provider
      require "ruby_llm"
      previous = [RubyLLM.config.anthropic_api_key, RubyLLM.config.gemini_api_key]
      RubyLLM.config.anthropic_api_key = "synthetic-no-network"
      RubyLLM.config.gemini_api_key = "synthetic-no-network"
      { "anthropic" => "claude-opus-4-8", "gemini" => "gemini-3.1-pro-preview" }.each do |provider, model|
        TurnKit.on_event = nil
        yield provider, model
      end
    ensure
      RubyLLM.config.anthropic_api_key, RubyLLM.config.gemini_api_key = previous if previous
      TurnKit.on_event = nil
    end

    def native_fixture(provider, model, tools:)
      calls = tools ? { "alpha" => RubyLLM::ToolCall.new(id: "alpha", name: "context_checking_tool", arguments: {}),
        "beta" => RubyLLM::ToolCall.new(id: "beta", name: "counting", arguments: {}) } : {}
      blocks = if provider == "anthropic"
        [{ "type" => "thinking", "thinking" => "private-fixture", "signature" => "opaque-fixture-a" },
          { "type" => "redacted_thinking", "data" => "opaque-fixture-redacted" },
          { "type" => "text", "text" => "public answer" }] + calls.values.map do |call|
          { "type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.arguments }
        end
      else
        [{ "thought" => true, "text" => "private-fixture", "thoughtSignature" => "opaque-fixture-thought" },
          { "text" => "public answer" }] + calls.values.map do |call|
          { "functionCall" => { "name" => call.name, "args" => call.arguments }, "thoughtSignature" => "opaque-fixture-#{call.id}" }
        end
      end
      body = provider == "anthropic" ? { "type" => "message", "role" => "assistant", "content" => blocks } :
        { "candidates" => [{ "content" => { "role" => "model", "parts" => blocks } }] }
      RubyLLM::Message.new({ role: :assistant, content: "public answer", tool_calls: calls,
        input_tokens: 87, output_tokens: 47, thinking_tokens: 31,
        cached_tokens: 19, cache_read_tokens: 19, cache_creation_tokens: 7, cache_write_tokens: 7,
        raw: Struct.new(:body).new(body),
        (RubyLLM::Chat.method_defined?(:generate) ? :model : :model_id) => model })
    end

    def native_blocks(response, provider)
      provider == "anthropic" ? response.raw.body.fetch("content") : response.raw.body.dig("candidates", 0, "content", "parts")
    end

    def native_messages(payload, provider)
      payload.fetch(provider == "gemini" ? "contents" : "messages")
    end

    def assert_native_payload(payload, first, provider)
      messages = native_messages(payload, provider)
      assistant = messages.find { |message| %w[assistant model].include?(message["role"]) }
      assert_equal native_blocks(first, provider), assistant.fetch(provider == "gemini" ? "parts" : "content")
      if provider == "gemini"
        results = messages.flat_map { |message| message.fetch("parts") }.filter_map { |part| part["functionResponse"] }
        assert_equal %w[context_checking_tool counting], results.map { |result| result["name"] }
      else
        results = messages.flat_map { |message| Array(message["content"]) }.select { |part| part.is_a?(Hash) && part["type"] == "tool_result" }
        assert_equal %w[alpha beta], results.map { |result| result["tool_use_id"] }
      end
    end
end
