# frozen_string_literal: true

require_relative "test_helper"

class EvaluationTest < Minitest::Test
  def questions
    { "urgent" => { "type" => "noul", "instructions" => "Urgent?" },
      "team" => { "type" => "choice", "instructions" => "Team?", "criteria" => { "sales" => nil, "support" => "Help" } },
      "severity" => { "type" => "score", "instructions" => "Severity?", "criteria" => ["Low", "Medium", "High"] } }
  end

  def payload
    { "model" => "jev-1.13.0", "usage" => { "input_tokens" => 137, "output_tokens" => 29 },
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.73 },
        "team" => { "type" => "choice", "choice" => "support", "confidence" => 0.64,
          "probabilities" => { "sales" => 0.13, "support" => 0.87 } },
        "severity" => { "type" => "score", "score" => 1.53, "confidence" => 0.58,
          "legend" => { "0" => "Low", "1" => "Medium", "2" => "High" },
          "probabilities" => { "0" => 0.09, "1" => 0.29, "2" => 0.62 } } } }
  end

  def adapter
    TurnKit::Adapters::CloudflareJev.new(account_id: "test-account", api_token: "secret-sentinel")
  end

  def evaluate(response_body, code: "200", headers: {})
    response = Struct.new(:body, :code, :headers) { def [](name) = headers[name] }.new(response_body, code, headers)
    http = Object.new
    http.define_singleton_method(:max_retries=) { |value| raise unless value == 0 }
    http.define_singleton_method(:request) do |request|
      raise unless request.path == "/client/v4/accounts/test-account/ai/run"
      raise unless request["Authorization"] == "Bearer secret-sentinel"
      raise unless JSON.parse(request.body).keys.sort == %w[input model]
      response
    end
    with_http(->(*_, **_, &block) { block.call(http) }) do
      adapter.evaluate(model: "typesafe/jev", state: "public fixture", questions: questions, timeout: 1)
    end
  end

  def with_http(implementation)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start, implementation)
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_all_primitives_and_both_documented_response_forms
    [payload, { "success" => true, "result" => payload, "errors" => [], "messages" => [] }].each do |body|
      result = evaluate(JSON.generate(body))
      assert_equal 137, result.usage.input_tokens
      assert_equal 29, result.usage.output_tokens
      assert_equal 0.73, result.answers.fetch("urgent").fetch("noul")
      assert_equal "support", result.answers.fetch("team").fetch("choice")
      assert_equal 1.53, result.answers.fetch("severity").fetch("score")
      refute_respond_to result, :text
      refute_respond_to result, :parts
    end
  end

  def test_mismatched_answers_types_options_probabilities_and_usage_are_rejected
    mutations = [
      ->(p) { p["answers"].delete("urgent") },
      ->(p) { p["answers"]["extra"] = p["answers"]["urgent"] },
      ->(p) { p["answers"]["urgent"]["type"] = "choice" },
      ->(p) { p["answers"]["urgent"]["noul"] = 1.01 },
      ->(p) { p["answers"]["urgent"]["noul"] = "0.5" },
      ->(p) { p["answers"]["team"]["choice"] = "other" },
      ->(p) { p["answers"]["team"]["confidence"] = -0.2 },
      ->(p) { p["answers"]["team"]["probabilities"]["sales"] = 0.8 },
      ->(p) { p["answers"]["team"]["probabilities"].delete("sales") },
      ->(p) { p["answers"]["severity"]["score"] = 2.01 },
      ->(p) { p["answers"]["severity"]["legend"]["2"] = {} },
      ->(p) { p["answers"]["severity"]["probabilities"]["3"] = 0 },
      ->(p) { p["usage"]["input_tokens"] = 1.5 },
      ->(p) { p["usage"]["output_tokens"] = -1 },
      ->(p) { p["usage"]["output_tokens"] = 9_007_199_254_740_992 },
      ->(p) { p["model"] = "" },
      ->(p) { p["text"] = "fake prose" }
    ]
    mutations.each do |mutation|
      value = payload
      mutation.call(value)
      error = assert_raises(TurnKit::EvaluationError) { evaluate(JSON.generate(value)) }
      assert_equal "malformed", error.status
      refute_includes error.message, "secret-sentinel"
    end
    value = payload
    value["answers"].clear
    error = assert_raises(TurnKit::EvaluationError) { evaluate(JSON.generate(value)) }
    assert_equal 137, error.usage.input_tokens, "observed usage survives invalid answers"
  end

  def test_input_follows_cloudflare_schema_not_direct_provider_limits
    q = questions
    q["severity"]["criteria"] = 11.times.map { |i| { "level" => i } }
    assert adapter.validate!(model: "typesafe/jev", state: nil, questions: q)
    [true, 3, Float::NAN, Object.new].each do |state|
      assert_raises(TurnKit::InputError) { adapter.validate!(model: "typesafe/jev", state: state, questions: questions) }
    end
    [ { "type" => "score", "instructions" => "x", "criteria" => ["one"] },
      { "type" => "noul", "instructions" => "x", "criteria" => { "maybe" => "x" } },
      { "type" => "choice", "instructions" => "x" },
      { "type" => "noul", "instructions" => "x", "model" => "jev-1.13" } ].each do |question|
      assert_raises(TurnKit::InputError) { adapter.validate!(model: "typesafe/jev", state: "x", questions: { "q" => question }) }
    end
    assert_raises(TurnKit::InputError) { adapter.validate!(model: "jev-latest", state: "x", questions: questions) }
    refute_includes adapter.inspect, "secret-sentinel"
  end

  def test_http_errors_retry_after_and_secret_safe_diagnostics
    { "400" => false, "401" => false, "403" => false, "429" => true, "503" => true }.each do |code, retryable|
      error = assert_raises(TurnKit::EvaluationError) { evaluate("secret-sentinel source text", code: code, headers: { "Retry-After" => "7" }) }
      assert_equal retryable, error.retryable?
      assert_equal 7, error.retry_after
      refute_includes error.message, "secret-sentinel"
    end
    quota = assert_raises(TurnKit::EvaluationError) { evaluate('{"errors":[{"code":3036}]}', code: "429") }
    refute quota.retryable?
    error = assert_raises(TurnKit::EvaluationError) { evaluate("not JSON secret-sentinel") }
    assert_nil error.cause
    assert_equal "malformed", error.status
    error = assert_raises(TurnKit::EvaluationError) { evaluate('{"success":false,"result":null,"errors":["secret-sentinel"]}') }
    assert_equal "unavailable", error.status
    with_http(->(*_, **_) { raise Timeout::Error, "secret-sentinel" }) do
      error = assert_raises(TurnKit::EvaluationError) { adapter.evaluate(model: "typesafe/jev", state: "x", questions: questions, timeout: 1) }
      assert_equal "uncertain", error.status
      assert_nil error.cause
    end
  end
end
