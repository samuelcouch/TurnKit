# frozen_string_literal: true

require "bundler/setup"
require "turnkit"

abort "Set TURNKIT_LIVE_EVALUATION=1 only after approving a paid Cloudflare call" unless ENV["TURNKIT_LIVE_EVALUATION"] == "1"

evaluator = TurnKit::Adapters::CloudflareJev.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN")
)
result = evaluator.evaluate(model: "typesafe/jev", timeout: 30,
  state: "A fictional customer says: please help, my payment failed and I need it fixed today.",
  questions: {
    urgency: { type: "noul", instructions: "Does the customer express urgency?" },
    department: { type: "choice", instructions: "Which department best fits this request?",
      criteria: { billing: "Payments and invoices", sales: "New product purchases", other: "Neither" } },
    frustration: { type: "score", instructions: "How frustrated does the customer sound?",
      criteria: ["Calm", "Frustrated", "Very angry"] }
  })
puts JSON.pretty_generate(result.to_h)
