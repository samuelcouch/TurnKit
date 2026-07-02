# frozen_string_literal: true

require_relative "test_helper"

class CostTest < Minitest::Test
  def test_workflow_run_honors_max_spend_guardrail
    expensive_client = FakeClient.new(TurnKit::Result.new(text: "too much", usage: TurnKit::Usage.new(cost: 0.02)))
    workflow = TurnKit::Agent.new(name: "workflow", orchestrator: true, client: expensive_client, max_spend: 0.01)

    run = workflow.run("Do expensive work")

    assert run.failed?
    error = TurnKit.store.load_turn(run.id).fetch("error")
    assert_includes error.fetch("message"), "cost limit reached"
    assert_equal 0.02, run.cost.total
  end
  def test_usage_tracks_cache_write_and_thinking_tokens
    usage = TurnKit::Usage.new(input_tokens: 2, output_tokens: 3, cached_tokens: 5, cache_write_tokens: 7, thinking_tokens: 11)

    assert_equal 28, usage.total_tokens
    assert_equal 7, usage.to_h.fetch("cache_write_tokens")
    assert_equal 11, usage.to_h.fetch("thinking_tokens")
  end
  def test_turn_aggregates_cache_write_tokens_and_cost
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 2, output_tokens: 3, cached_tokens: 5, cache_write_tokens: 7, cost: 0.01)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", client: client)

    turn = agent.conversation.ask("Hi")
    record = TurnKit.store.load_turn(turn.id)

    assert_equal 7, record.fetch("usage").fetch("cache_write_tokens")
    assert_equal 17, record.fetch("usage").fetch("total_tokens")
    assert_equal 0.01, record.fetch("cost")
  end
  def test_cost_is_calculated_from_model_rates
    TurnKit.cost_rates = {
      "model-a" => {
        input: 1.00,
        output: 2.00,
        cache_read: 0.10,
        cache_write: 1.25
      }
    }
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 1_000_000, output_tokens: 500_000, cached_tokens: 100_000, cache_write_tokens: 200_000)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", client: client)
    conversation = agent.conversation

    turn = conversation.ask("Hi")
    record = TurnKit.store.load_turn(turn.id)

    assert_equal 2.26, turn.cost.total
    assert_equal 2.26, conversation.cost.total
    assert_equal 2.26, agent.cost.total
    assert_equal 1_800_000, turn.usage.total_tokens
    assert_equal 1_800_000, conversation.usage.total_tokens
    assert_equal 1_800_000, agent.usage.total_tokens
    assert_equal({ "input" => 1.0, "output" => 1.0, "cache_read" => 0.01, "cache_write" => 0.25, "thinking" => 0.0, "total" => 2.26 }, record.fetch("usage").fetch("cost_details"))
  end
  def test_cost_is_calculated_from_thinking_token_rates
    TurnKit.cost_rates = { "model-a" => { input: 1.00, output: 1.00, thinking: 3.00 } }
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 1_000_000, output_tokens: 1_000_000, thinking_tokens: 500_000)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", client: client)

    turn = agent.conversation.ask("Hi")

    assert_equal 2_500_000, turn.usage.total_tokens
    assert_equal 0.5, turn.usage.thinking_tokens / 1_000_000.0
    assert_equal 3.5, turn.cost.total
  end
  def test_cost_calculator_can_override_pricing
    TurnKit.cost_calculator = ->(usage, model) { { input: usage.input_tokens * 0.001, output: model == "model-a" ? 0.25 : 0 } }
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 2, output_tokens: 3)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", client: client)

    turn = agent.conversation.ask("Hi")

    assert_equal 0.252, turn.cost.total
  end
  def test_max_spend_uses_calculated_cost
    TurnKit.cost_rates = { "model-a" => { input: 1.00, output: 1.00 } }
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 1_000_000)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", client: client, max_spend: 0.50)

    turn = agent.conversation.ask("Hi")

    assert turn.failed?
    assert_equal "cost limit reached", TurnKit.store.load_turn(turn.id).fetch("error").fetch("message")
  end
  def test_codex_adapter_uses_codex_exec_and_records_subscription_usage_without_cost
    calls = []
    runner = lambda do |command, stdin_data:, chdir:|
      calls << { command: command, stdin_data: stdin_data, chdir: chdir }
      output_path = command[command.index("-o") + 1]
      File.write(output_path, "Codex answer")
      stdout = [
        { type: "thread.started", thread_id: "thread_1" },
        { type: "turn.completed", usage: { input_tokens: 100, cached_input_tokens: 40, output_tokens: 12, reasoning_output_tokens: 3 } }
      ].map(&:to_json).join("\n")
      [ stdout, "", TurnKit::Adapters::Codex::Status.new(successful: true) ]
    end
    adapter = TurnKit::Adapters::Codex.new(command: "codex", runner: runner)

    result = adapter.chat(
      model: "gpt-5.4",
      messages: [ { role: "user", content: "Fix the bug" } ],
      tools: [],
      instructions: "You are a coding agent."
    )

    assert_equal "Codex answer", result.text
    assert_equal "gpt-5.4", result.model
    assert_equal 60, result.usage.input_tokens
    assert_equal 40, result.usage.cached_tokens
    assert_equal 12, result.usage.output_tokens
    assert_equal 3, result.usage.thinking_tokens
    assert_nil result.usage.cost
    assert_equal [ "codex", "exec", "--json", "--sandbox", "read-only", "--model", "gpt-5.4" ], calls.first.fetch(:command).first(7)
    assert_includes calls.first.fetch(:stdin_data), "System instructions:\nYou are a coding agent."
    assert_includes calls.first.fetch(:stdin_data), "user:\nFix the bug"
  end
  def test_turn_paint_persists_image_usage_cost_and_events
    image = TurnKit::ImageResult.new(url: "https://example.com/image.png", mime_type: "image/png", model: "image-model", provider: "gemini", usage: TurnKit::Usage.new(input_tokens: 3, cost: 0.04))
    client = FakeClient.new(TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], usage: image.usage, model: "image-model"))
    events = []
    agent = TurnKit::Agent.new(name: "artist", client: client, on_event: ->(event) { events << event })
    turn = agent.run("Generate later", async: true).turn

    generated = turn.paint("paint", model: "image-model", provider: :gemini, size: "1024x576", metadata: { article_id: 1 })

    assert_equal "https://example.com/image.png", generated.url
    assert_equal 3, turn.reload.usage.input_tokens
    assert_equal 0.04, turn.cost.total
    assert turn.completed?
    assert_equal "https://example.com/image.png", turn.output_text
    assert_equal "image", turn.output_data.fetch("type")
    assert TurnKit::Message.new(TurnKit.store.list_messages(turn.conversation.id).last).image?
    assert_includes events.map(&:type), "turn.started"
    assert_includes events.map(&:type), "image.requested"
    assert_includes events.map(&:type), "image.completed"
    assert_includes events.map(&:type), "turn.completed"
    assert_equal({ article_id: 1 }, client.calls.first.fetch(:metadata).slice(:article_id))
  end
  def test_image_tool_budget_errors_fail_the_turn
    image = TurnKit::ImageResult.new(url: "https://example.com/header.png", model: "image-model", usage: TurnKit::Usage.new(cost: 0.02))
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "image_1", name: "header_image", arguments: { title: "Launch" }) ]),
      TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], usage: image.usage, model: "image-model")
    )
    agent = TurnKit::Agent.new(name: "publisher", client: client, tools: [ HeaderImageTool ], max_spend: 0.01)

    run = agent.run("Generate header")

    assert run.failed?
    assert_equal "cost limit reached", run.error.fetch("message")
  end
  def test_turn_view_media_persists_usage_cost_and_events
    media = TurnKit::MediaInput.bytes("png", mime_type: "image/png", filename: "header.png")
    analysis = TurnKit::MediaAnalysisResult.new(text: "approved", data: { "approved" => true }, model: "media-model", provider: "gemini", usage: TurnKit::Usage.new(input_tokens: 4, cost: 0.05), media: media.to_h)
    client = FakeClient.new(TurnKit::Result.new(parts: [ analysis.to_h.merge("type" => "media_analysis") ], usage: analysis.usage, model: "media-model"))
    events = []
    agent = TurnKit::Agent.new(name: "reviewer", client: client, on_event: ->(event) { events << event })
    turn = agent.run("Review later", async: true).turn

    result = turn.view_media(media, objective: "Review image", model: "media-model", provider: :gemini, metadata: { article_id: 1 })

    assert_equal "approved", result.text
    assert_equal 4, turn.reload.usage.input_tokens
    assert_equal 0.05, turn.cost.total
    assert turn.completed?
    assert_equal "approved", turn.output_text
    assert_equal "media_analysis", turn.output_data.fetch("type")
    assert TurnKit::Message.new(TurnKit.store.list_messages(turn.conversation.id).last).media_analysis?
    assert_includes events.map(&:type), "turn.started"
    assert_includes events.map(&:type), "media.requested"
    assert_includes events.map(&:type), "media.completed"
    assert_includes events.map(&:type), "turn.completed"
    assert_equal({ article_id: 1 }, client.calls.first.fetch(:metadata).slice(:article_id))
  end
  def test_view_media_budget_errors_fail_the_turn
    file = Tempfile.new([ "header", ".png" ])
    file.write("png")
    file.close
    media = TurnKit::MediaInput.new(file.path)
    analysis = TurnKit::MediaAnalysisResult.new(text: "approved", model: "media-model", usage: TurnKit::Usage.new(cost: 0.02), media: media.to_h)
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "media_1", name: "header_review", arguments: { path: file.path }) ]),
      TurnKit::Result.new(parts: [ analysis.to_h.merge("type" => "media_analysis") ], usage: analysis.usage, model: "media-model")
    )
    agent = TurnKit::Agent.new(name: "publisher", client: client, tools: [ HeaderReviewTool ], max_spend: 0.01)

    run = agent.run("Review header")

    assert run.failed?
    assert_equal "cost limit reached", run.error.fetch("message")
  ensure
    file&.unlink
  end
  def test_budget_resume_seeds_persisted_iterations_cost_and_tool_counts
    agent = TurnKit::Agent.new(name: "worker", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    run = agent.run("Later", async: true)
    TurnKit.store.update_turn(run.id, options: { "iterations" => 1 }, cost: 0.05, started_at: Time.utc(2026, 1, 1))
    TurnKit.store.create_tool_execution("turn_id" => run.id, "tool_call_id" => "call_1", "tool_name" => "status_tool", "status" => "completed")

    budget = TurnKit::Budget.resume(
      store: TurnKit.store,
      root_turn_id: run.root_turn_id,
      limits: { max_iterations: 2, timeout: 60, max_depth: 3, max_tool_executions: 2, max_tool_executions_by_name: { "status_tool" => 1 }, max_spend: 0.10 }
    )

    assert_raises(TurnKit::BudgetError) { budget.count_tool_execution!("status_tool") }
    budget.count_iteration!
    assert_raises(TurnKit::BudgetError) { budget.count_iteration! }
    assert_raises(TurnKit::BudgetError) { budget.add_cost!(0.06) }
  end
end
