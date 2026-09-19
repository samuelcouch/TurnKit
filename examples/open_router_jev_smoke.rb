# frozen_string_literal: true

# One synthetic paid Decisions request; the producing chat response is local.
require "bundler/setup"
require "turnkit"

abort "Set TURNKIT_LIVE_OPENROUTER_JEV=1 only after approving a paid call" unless ENV["TURNKIT_LIVE_OPENROUTER_JEV"] == "1"
abort "OPENROUTER_API_KEY is missing" if ENV["OPENROUTER_API_KEY"].to_s.empty?

class SmokeJev < TurnKit::Adapters::OpenRouterJev
  attr_reader :calls

  def evaluate(**options)
    @calls = (@calls || 0) + 1
    raise "Smoke dispatch cap exceeded" if @calls > 1
    super
  end
end

class SmokeCandidate < TurnKit::Client
  def chat(**)
    TurnKit::Result.new(text: "Synthetic candidate; no chat inference was used.")
  end
end

evaluator = SmokeJev.new(api_key: ENV.fetch("OPENROUTER_API_KEY"), billing_identity: "turnkit-public-smoke")
TurnKit.store = TurnKit::MemoryStore.new
TurnKit.cost_rates["openrouter/typesafe/jev-1.13"] = { input: 0.042, output: 0 }
result = nil
replayed = false
failure = nil
audit = lambda do |output, turn:|
  options = {
    evaluator: evaluator, model: "typesafe/jev-1.13", purpose: :smoke,
    policy_version: "synthetic-v1", candidate: output, max_attempts: 1, timeout: 30,
    state: "Fictional Acorn reports: For fiscal 2024, adjusted revenue was USD 17 million. This is not GAAP revenue. Fiscal 2025 results have not been published.",
    questions: {
      supported: { type: "noul", instructions: "Does the source explicitly report adjusted revenue for fiscal 2024?" },
      unsupported: { type: "noul", instructions: "Does the source provide GAAP revenue results for fiscal 2025?" },
      period: { type: "choice", instructions: "Which fiscal period has a reported revenue result?",
        criteria: { fy2023: "Fiscal 2023", fy2024: "Fiscal 2024", fy2025: "Fiscal 2025" } },
      basis: { type: "choice", instructions: "What accounting basis is the reported revenue explicitly on?",
        criteria: { gaap: "GAAP", adjusted: "Adjusted, not GAAP", unspecified: "Not specified" } },
      mismatch: { type: "score", instructions: "How well does the source support this claim: fiscal 2025 GAAP revenue was USD 17 million?",
        criteria: ["Unsupported or contradicted", "Partly supported", "Fully supported"] }
    }
  }
  result = turn.internal_evaluation(**options)
  replay = turn.internal_evaluation(**options)
  replayed = replay.receipt_id == result.receipt_id && replay.to_h == result.to_h
  nil
rescue TurnKit::EvaluationError => error
  failure = { status: error.status, http_status: error.http_status, model: error.model,
    observed_usage: error.usage&.to_h }
  nil
end

run = TurnKit::Agent.new(name: "jev-smoke", model: "local-fixture", client: SmokeCandidate.new,
  output_policy: audit, max_spend: 0.01).run("Evaluate the synthetic fixture only")
checks = if result
  a = result.answers
  { supported: a["supported"]["noul"] > 0.8, unsupported: a["unsupported"]["noul"] < 0.2,
    period: a["period"]["choice"] == "fy2024", basis: a["basis"]["choice"] == "adjusted",
    mismatch: a["mismatch"]["score"] < 0.5 }
end
puts JSON.pretty_generate(request_count: evaluator.calls || 0, completed: run.completed?, failure: failure,
  result: result&.to_h, receipt_replayed: replayed, semantic_checks: checks,
  known_or_estimated_cost_usd: run.cost.total, unknown_cost: run.cost.unknown?)
abort "Smoke failed; do not automatically retry an uncertain or failed request" unless run.completed? && result && replayed && checks.values.all? && evaluator.calls == 1
