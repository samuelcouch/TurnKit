# frozen_string_literal: true

require_relative "test_helper"

class OpenRouterJevTest < Minitest::Test
  MODEL = "typesafe/jev-1.13"

  def adapter
    TurnKit::Adapters::OpenRouterJev.new(api_key: "secret-sentinel", billing_identity: "test-billing")
  end

  def questions
    { "supported" => { "type" => "noul", "instructions" => "Supported?" },
      "basis" => { "type" => "choice", "instructions" => "Basis?", "criteria" => { "gaap" => nil, "adjusted" => "Adjusted" } },
      "support" => { "type" => "score", "instructions" => "Support?", "criteria" => ["None", "Partial", "Full"] } }
  end

  def payload
    { "id" => "gen-test", "provider" => "TypeSafe", "model" => "typesafe/jev-1.13-20260917",
      "usage" => { "input_tokens" => 317, "output_tokens" => 53, "cost" => 0.000019992 },
      "answers" => {
        "supported" => { "type" => "noul", "noul" => 0.12 },
        "basis" => { "type" => "choice", "choice" => "adjusted", "confidence" => 0.72,
          "probabilities" => { "gaap" => 0.09, "adjusted" => 0.91 } },
        "support" => { "type" => "score", "score" => 0.29, "confidence" => 0.61,
          "probabilities" => { "0" => 0.75, "1" => 0.21, "2" => 0.04 },
          "legend" => { "0" => "None", "1" => "Partial", "2" => "Full" } } } }
  end

  def with_response(body = payload, code: 200, retry_after: nil, failure: nil)
    response = Struct.new(:body, :code, :delay) { def [](name) = name == "Retry-After" ? delay : nil }
      .new(body.is_a?(String) ? body : JSON.generate(body), code.to_s, retry_after)
    http = Object.new
    http.define_singleton_method(:max_retries=) { |value| raise "automatic retry enabled" unless value == 0 }
    http.define_singleton_method(:request) do |request|
      @requests << request
      raise failure if failure
      response
    end
    @requests = []
    http.instance_variable_set(:@requests, @requests)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
      raise "wrong endpoint" unless host == "openrouter.ai" && port == 443 && options[:use_ssl]
      raise "missing timeouts" unless %i[open_timeout read_timeout write_timeout].all? { |k| options[k].positive? }
      block.call(http)
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  def evaluate
    adapter.evaluate(model: MODEL, state: { "fixture" => "original context" }, questions: questions, timeout: 1)
  end

  def test_wire_contract_all_primitives_and_reported_cost
    with_response do
      result = evaluate
      request = @requests.fetch(0)
      assert_equal "/api/alpha/decisions", request.path
      assert_equal "POST", request.method
      assert_equal "Bearer secret-sentinel", request["Authorization"]
      assert_equal "application/json", request["Content-Type"]
      assert_equal "application/json", request["Accept"]
      assert_nil request["HTTP-Referer"]
      assert_nil request["X-Title"]
      assert_nil request["X-OpenRouter-Title"]
      assert_equal({ "model" => MODEL, "state" => { "fixture" => "original context" }, "questions" => questions }, JSON.parse(request.body))
      assert_equal "typesafe/jev-1.13-20260917", result.model
      assert_equal 0.12, result.answers["supported"]["noul"]
      assert_equal "adjusted", result.answers["basis"]["choice"]
      assert_equal 0.29, result.answers["support"]["score"]
      assert_equal [317, 53], [result.usage.input_tokens, result.usage.output_tokens]
      TurnKit.cost_rates[adapter.cost_model(model: MODEL)] = { input: 10, output: 20 }
      assert_equal 0.000019992, TurnKit::Cost.from_usage(result.usage, model: adapter.cost_model(model: MODEL)).total
      refute_respond_to result, :text
      refute_respond_to result, :parts
    end
    refute_includes adapter.inspect, "secret-sentinel"
    refute_includes adapter.identity.to_s, "secret-sentinel"
    refute_equal adapter.identity, TurnKit::Adapters::OpenRouterJev.new(api_key: "rotated", billing_identity: "other").identity
    assert_equal adapter.identity, TurnKit::Adapters::OpenRouterJev.new(api_key: "rotated", billing_identity: "test-billing").identity
  end

  def test_missing_cost_uses_explicit_fallback_not_zero
    body = payload
    body["usage"].delete("cost")
    with_response(body) do
      result = evaluate
      assert_nil result.usage.cost
      TurnKit.cost_rates[adapter.cost_model(model: MODEL)] = { input: 0.042, output: 0 }
      assert_in_delta 0.000013314, TurnKit::Cost.from_usage(result.usage, model: adapter.cost_model(model: MODEL)).total, 1e-12
    end
  end

  def test_optional_fields_are_not_fabricated_and_invalid_answers_retain_charge
    mutations = [
      ->(p) { p["answers"].delete("supported") },
      ->(p) { p["answers"]["extra"] = p["answers"]["supported"] },
      ->(p) { p["answers"]["supported"]["type"] = "choice" },
      ->(p) { p["answers"]["supported"]["noul"] = 1.01 },
      ->(p) { p["answers"]["basis"]["choice"] = "other" },
      ->(p) { p["answers"]["basis"]["probabilities"]["gaap"] = 0.8 },
      ->(p) { p["answers"]["basis"]["confidence"] = "0.9" },
      ->(p) { p["answers"]["support"]["score"] = -0.1 },
      ->(p) { p["answers"]["support"]["legend"]["2"] = {} },
      ->(p) { p["usage"]["input_tokens"] = 3.5 }
    ]
    %w[confidence probabilities].each { |key| mutations << ->(p) { p["answers"]["basis"].delete(key) } }
    %w[confidence probabilities legend].each { |key| mutations << ->(p) { p["answers"]["support"].delete(key) } }
    mutations.each do |mutation|
      body = payload
      mutation.call(body)
      with_response(body) do
        error = assert_raises(TurnKit::EvaluationError) { evaluate }
        assert_equal "malformed", error.status
        assert_equal 0.000019992, error.usage.cost
        assert_nil error.cause
      end
    end
    [nil, -0.1, "0.2"].each do |cost|
      body = payload
      body["usage"]["cost"] = cost
      with_response(body) { assert_raises(TurnKit::EvaluationError) { evaluate } }
    end
  end

  def test_input_schema_differences_are_checked_before_http
    [nil, true, 2].each do |state|
      assert_raises(TurnKit::InputError) { adapter.validate!(model: MODEL, state: state, questions: questions) }
    end
    [ { type: "noul", instructions: nil },
      { type: "noul", instructions: "x", criteria: nil },
      { type: "noul", instructions: "x", criteria: { true: "yes" } },
      { type: "score", instructions: "x", criteria: ["low", nil] } ].each do |q|
      assert_raises(TurnKit::InputError) { adapter.validate!(model: MODEL, state: [], questions: { q: q }) }
    end
    assert adapter.validate!(model: MODEL, state: [], questions: questions)
    assert_raises(TurnKit::InputError) { adapter.validate!(model: "~typesafe/jev-latest", state: "x", questions: questions) }
  end

  def test_errors_redaction_retry_after_and_no_transport_retries
    [400, 401, 402, 403, 404, 413, 429, 500, 502, 503, 524, 529].each do |code|
      with_response("secret-sentinel private context", code: code, retry_after: "7") do
        error = assert_raises(TurnKit::EvaluationError) { evaluate }
        assert_equal code >= 500 || code == 429, error.retryable?
        assert_equal code >= 500 ? "uncertain" : "unavailable", error.status
        assert_equal code, error.http_status
        assert_equal 7, error.retry_after
        assert_nil error.usage
        refute_includes error.message, "secret-sentinel"
        assert_equal 1, @requests.size
      end
    end
    with_response(code: 429, retry_after: (Time.now + 30).httpdate) do
      error = assert_raises(TurnKit::EvaluationError) { evaluate }
      assert_operator error.retry_after, :>, 28
    end
    [Timeout::Error, EOFError, Errno::ECONNRESET].each do |type|
      with_response(failure: type.new("secret-sentinel")) do
        error = assert_raises(TurnKit::EvaluationError) { evaluate }
        assert_equal "uncertain", error.status
        assert_nil error.cause
        assert_equal 1, @requests.size
      end
    end
    with_response("not JSON secret-sentinel") do
      error = assert_raises(TurnKit::EvaluationError) { evaluate }
      assert_equal "malformed", error.status
      assert_nil error.cause
    end
  end

  def test_runtime_replay_and_malformed_billable_response_account_once
    [payload, payload.merge("answers" => {})].each do |body|
      TurnKit.store = TurnKit::MemoryStore.new
      ids = []
      audit = ->(output, turn:) do
        2.times do
          begin
            result = turn.internal_evaluation(evaluator: adapter, model: MODEL, purpose: :support,
              policy_version: "v1", candidate: output, state: "public fixture", questions: questions)
            ids << result.receipt_id
          rescue TurnKit::EvaluationError => error
            assert_equal "malformed", error.status
          end
        end
        nil
      end
      with_response(body) do
        run = TurnKit::Agent.new(name: "router-audit", client: FakeClient.new, output_policy: audit).run("work")
        assert run.completed?, run.error.inspect
        assert_equal 1, @requests.size
        assert_equal 317, run.usage.input_tokens
        assert_equal 53, run.usage.output_tokens
        assert_in_delta 0.000019992, run.cost.total, 1e-12
        assert_equal ids.first, ids.last unless ids.empty?
      end
    end
  end

  def test_smoke_script_checks_semantics_and_replay_without_live_transport
    body = payload
    body["answers"] = {
      "supported" => { "type" => "noul", "noul" => 0.98 },
      "unsupported" => { "type" => "noul", "noul" => 0.03 },
      "period" => { "type" => "choice", "choice" => "fy2024", "confidence" => 0.9,
        "probabilities" => { "fy2023" => 0.01, "fy2024" => 0.97, "fy2025" => 0.02 } },
      "basis" => { "type" => "choice", "choice" => "adjusted", "confidence" => 0.91,
        "probabilities" => { "gaap" => 0.01, "adjusted" => 0.96, "unspecified" => 0.03 } },
      "mismatch" => { "type" => "score", "score" => 0.07, "confidence" => 0.89,
        "probabilities" => { "0" => 0.95, "1" => 0.03, "2" => 0.02 },
        "legend" => { "0" => "Unsupported or contradicted", "1" => "Partly supported", "2" => "Fully supported" } }
    }
    saved = ENV.to_h.slice("OPENROUTER_API_KEY", "TURNKIT_LIVE_OPENROUTER_JEV")
    ENV["OPENROUTER_API_KEY"] = "secret-sentinel"
    ENV["TURNKIT_LIVE_OPENROUTER_JEV"] = "1"
    with_response(body) do
      output, = capture_io { load File.expand_path("../examples/open_router_jev_smoke.rb", __dir__), true }
      report = JSON.parse(output)
      assert_equal 1, report["request_count"]
      assert report["receipt_replayed"]
      assert report["semantic_checks"].values.all?
      assert_equal 0.000019992, report["known_or_estimated_cost_usd"]
      assert_equal 1, @requests.size
    end
    # A schema-valid but wrong period must fail the smoke, not just print success.
    body["answers"]["period"]["choice"] = "fy2025"
    with_response(body) do
      capture_io do
        error = assert_raises(SystemExit) { load File.expand_path("../examples/open_router_jev_smoke.rb", __dir__), true }
        refute error.success?
      end
      assert_equal 1, @requests.size
    end
  ensure
    %w[OPENROUTER_API_KEY TURNKIT_LIVE_OPENROUTER_JEV].each { |key| ENV[key] = saved[key] } if saved
  end
end
