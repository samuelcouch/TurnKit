# frozen_string_literal: true

# Included in both memory and PostgreSQL background suites. No provider calls:
# ReplayClient renders the installed RubyLLM codec and returns synthetic output.
module PromptCache
  def test_openai_preview_does_not_create_a_provider_chat_or_persist_context
    require "ruby_llm"
    original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**| raise "preview must not create a chat" }
    agent = register("cache_preview", model: "gpt-4.1-mini", client: TurnKit::Adapters::RubyLLM.new)
    conversation = agent.conversation
    turn = conversation.build_turn
    assert_includes turn.preview.messages.last[:content], "[TurnKit current context"
    assert_empty conversation.messages
  ensure
    RubyLLM.define_singleton_method(:chat, original_chat) if original_chat
  end

  def test_openai_context_snapshots_preserve_wire_prefix_and_recover_without_duplicates
    with_openai_cache_fixture do
      skip "Responses requires RubyLLM 2" unless RubyLLM::Chat.method_defined?(:generate)
      first = cache_response(tools: true)
      client = NativeProviderReplay::ReplayClient.new(first, cache_response)
      value = "remaining=9; claims=alpha"
      run = register("cache_recovery", model: "gpt-4.1-mini", client: client,
        tools: [ContextCheckingTool, self.class::CountingTool.new],
        context_contributors: [->(_) { value }]).run("research", async: true).perform_later
      client.before_response = lambda do |number|
        if number == 1
          value = "remaining=4; claims=beta"
          run.pause!
        elsif number == 2
          raise IOError, "synthetic worker loss before response"
        end
      end
      TurnKit::Background.perform(run.id)
      assert run.reload.paused?
      TurnKit.load_turn(run.id).resume!
      assert_raises(IOError) { drain_jobs }
      expire(run)
      TurnKit::Background.reconcile
      drain_jobs
      assert run.reload.completed?

      initial, next_request, retry_request = client.payloads
      assert_equal initial.fetch("instructions"), next_request.fetch("instructions")
      refute_includes initial.fetch("instructions"), "remaining="
      assert_equal initial.fetch("input"), next_request.fetch("input").take(initial.fetch("input").length)
      assert_equal next_request, retry_request
      tail = next_request.fetch("input").drop(initial.fetch("input").length)
      assert_equal first.raw.body.fetch("output"), tail.take(3)
      assert_equal %w[alpha beta], tail[3, 2].map { |item| item.fetch("call_id") }
      assert_equal ["function_call_output"] * 2, tail[3, 2].map { |item| item.fetch("type") }
      assert_equal "user", tail.last.fetch("role")
      assert_includes tail.last.to_json, "remaining=4; claims=beta"
      refute_includes tail.last.to_json, "remaining=9; claims=alpha"
      snapshots = run.turn.conversation.messages.select { |message| message.kind == "dynamic_context" }
      assert_equal 2, snapshots.length
      refute run.turn.conversation.messages_after(0).any? { |message| message.kind == "dynamic_context" }
      assert_equal 2, run.tool_executions.count(&:completed?)

      # A later turn reloads durable history and extends the exact prior input.
      client.before_response = nil
      client.instance_variable_get(:@responses) << cache_response
      run.turn.conversation.ask("followup", async: true).perform_later
      drain_jobs
      assert_equal next_request.fetch("input"), client.payloads.last.fetch("input").take(next_request.fetch("input").length)
    end
  end

  def test_openai_steering_survives_unchanged_or_changed_context_and_resume
    with_openai_cache_fixture do
      [false, true].each do |changed|
        client = NativeProviderReplay::ReplayClient.new(cache_response)
        value = "mode=blind; claims=alpha"
        run = register("cache_steering_#{changed}", model: "gpt-4.1-mini", client: client,
          context_contributors: [->(_) { value }]).run("research", async: true).perform_later
        TurnKit.on_event = ->(event) { run.pause! if event.type == "model.requested" }
        TurnKit::Background.perform(run.id)
        assert run.reload.paused?
        assert_empty client.payloads
        TurnKit.on_event = nil
        run.steer!("Owner: prioritize the safety evidence", key: "owner-focus")
        value = "mode=reveal; claims=beta" if changed
        TurnKit.load_turn(run.id).resume!
        # Environment remains anchored to turn.started_at across minute changes.
        original_clock = TurnKit::Clock.method(:now)
        later = TurnKit.load_turn(run.id).started_at + 65
        begin
          TurnKit::Clock.define_singleton_method(:now) { later }
          drain_jobs
        ensure
          TurnKit::Clock.define_singleton_method(:now, original_clock)
        end
        assert run.reload.completed?
        payload = client.payloads.fetch(0)
        input = payload.fetch(payload.key?("input") ? "input" : "messages")
        assert_equal 1, input.count { |item| item.to_json.include?("Owner: prioritize the safety evidence") }
        snapshots = run.turn.conversation.messages.select { |message| message.kind == "dynamic_context" }
        assert_equal changed ? 2 : 1, snapshots.length
        assert_includes snapshots.last.text, value
        assert_includes input.to_json, value
      end
    end
  end

  def test_openai_direct_adapter_and_configuration_preserve_stable_instructions
    with_openai_cache_fixture do
      protocols = RubyLLM::Chat.method_defined?(:generate) ? [nil, :responses, :chat_completions] : [nil]
      protocols.product([:auto, :off]).each do |protocol, caching|
        TurnKit.prompt_cache = caching
        client = NativeProviderReplay::ReplayClient.new(cache_response, cache_response)
        client.instance_variable_set(:@protocol, protocol)
        assert client.dynamic_context_in_history?(model: "gpt-4.1-mini")
        %w[old new].each do |context|
          client.chat(model: "gpt-4.1-mini", instructions: "stable", dynamic_instructions: context,
            messages: [{ role: :user, content: "task" }], tools: [])
        end
        before, after = client.payloads
        if before.key?("instructions")
          assert_equal "stable", before.fetch("instructions")
          assert_equal "stable", after.fetch("instructions")
          assert_equal false, after.fetch("store")
          refute after.key?("prompt_cache_options")
          input = after.fetch("input")
        else
          assert_equal({ "role" => "developer", "content" => "stable" }, after.fetch("messages").first)
          input = after.fetch("messages").drop(1)
        end
        assert_equal "task", input.first.fetch("content")
        assert_equal "user", input.last.fetch("role")
        assert_includes input.last.fetch("content"), "new"
      end
    end
  end

  def test_context_deduplication_empty_snapshot_compaction_and_ordinary_client
    client = Class.new(FakeClient) do
      def dynamic_context_in_history?(model:) = true
    end.new
    value = "current claims"
    agent = register("context_snapshots", client: client, prompt_sections: [:instructions, :live_context],
      context_contributors: [->(_) { value }])
    conversation = agent.conversation
    turn = conversation.build_turn
    preview = turn.preview
    assert_empty conversation.messages
    assert_equal preview.messages, turn.preview.messages
    assert_empty conversation.messages
    first = turn.send(:model_request)
    assert_equal preview.messages, first.messages
    assert_empty first.dynamic_instructions
    assert_equal first.messages, turn.send(:model_request).messages
    assert_equal 1, conversation.messages.count { |message| message.kind == "dynamic_context" }
    # Reloading, rather than in-memory state, drives deduplication.
    reloaded = TurnKit.load_turn(turn.id)
    assert_equal first.messages, reloaded.send(:model_request).messages
    value = nil
    cleared = reloaded.send(:model_request)
    refute_includes cleared.messages.last.fetch(:content), "current claims"
    assert_equal 2, conversation.messages.count { |message| message.kind == "dynamic_context" }
    assert_equal cleared.messages, reloaded.send(:model_request).messages

    value = "current claims"
    restored = reloaded.send(:model_request)
    last = conversation.messages.last
    conversation.append_message(role: "assistant", kind: "context_summary", text: "summary", turn_id: turn.id,
      metadata: { "compaction" => { "replaces_from_sequence" => 1, "replaces_through_sequence" => last.sequence } })
    compacted = reloaded.send(:model_request)
    assert_equal restored.messages.last, compacted.messages.last
    assert_equal 4, conversation.messages.count { |message| message.kind == "dynamic_context" }
    assert_equal 1, compacted.messages.count { |message| message[:content].include?("[TurnKit current context") }

    # A different provider/custom client retains the original contract and
    # does not receive historical OpenAI-only snapshots.
    ordinary = FakeClient.new
    other_agent = register("ordinary_context", client: ordinary, context_contributors: [->(_) { "fresh context" }])
    other_turn = conversation.build_turn(agent: other_agent)
    request = other_turn.send(:model_request)
    assert_includes request.dynamic_instructions, "fresh context"
    refute request.messages.any? { |message| message[:content].include?("[TurnKit current context") }
  end

  private
    def with_openai_cache_fixture
      require "ruby_llm"
      previous = RubyLLM.config.openai_api_key
      RubyLLM.config.openai_api_key = "offline-placeholder"
      yield
    ensure
      RubyLLM.config.openai_api_key = previous
    end

    def cache_response(tools: false)
      calls = tools ? {
        "alpha" => RubyLLM::ToolCall.new(id: "alpha", name: "context_checking_tool", arguments: {}),
        "beta" => RubyLLM::ToolCall.new(id: "beta", name: "counting", arguments: {})
      } : {}
      output = [{ "type" => "reasoning", "id" => "rs_fixture", "encrypted_content" => "opaque-fixture", "summary" => [] }]
      output += calls.values.map do |call|
        { "type" => "function_call", "id" => "fc_#{call.id}", "call_id" => call.id, "name" => call.name, "arguments" => "{}" }
      end
      unless tools
        output << { "type" => "message", "id" => "msg_fixture", "role" => "assistant",
          "content" => [{ "type" => "output_text", "text" => "done", "annotations" => [] }] }
      end
      RubyLLM::Message.new(role: :assistant, content: tools ? "" : "done", tool_calls: calls,
        raw: Struct.new(:body).new({ "object" => "response", "status" => "completed", "output" => output }))
    end
end
