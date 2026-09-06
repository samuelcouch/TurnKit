# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "base64"
require "json"
require "turnkit"
require_relative "../shared/model_registry"

MODEL = ENV.fetch("TURNKIT_MEDIA_MODEL", "gemini-3.8-flash")
PROVIDER = :gemini
TurnKitExamples.prepare_model(MODEL)

SMOKE_PNG = Base64.decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/l8LeWQAAAABJRU5ErkJggg=="
)

schema = {
  type: "object",
  properties: {
    media_type: { type: "string" },
    visible_content: { type: "string" },
    usable_for_review: { type: "boolean" },
    confidence: { type: "string", enum: %w[low medium high] }
  },
  required: %w[media_type visible_content usable_for_review confidence]
}

media = if ARGV[0]
  TurnKit::MediaInput.new(ARGV[0])
else
  TurnKit::MediaInput.bytes(SMOKE_PNG, mime_type: "image/png", filename: "turnkit-smoke.png")
end

events = []
agent = TurnKit::Agent.new(
  name: "media_analysis_smoke_test",
  client: TurnKit::Adapters::RubyLLM.new,
  max_spend: 0.25,
  on_event: ->(event) { events << event }
)

turn = agent.run("Analyze media with #{MODEL}.", async: true).turn
analysis = turn.view_media(
  media,
  objective: <<~TEXT.strip,
    Identify what kind of media this is and summarize the visible or audible
    content. For the default smoke-test image, describe the tiny generated image
    plainly instead of inventing details.
  TEXT
  model: MODEL,
  provider: PROVIDER,
  output_schema: schema,
  metadata: { example: "media_analysis/gemini_3_flash_view_media" }
)

puts JSON.pretty_generate(
  status: turn.reload.status,
  model: analysis.model,
  provider: analysis.provider,
  media: analysis.media,
  text: analysis.text,
  data: analysis.data,
  usage: turn.usage.to_h,
  cost: turn.cost.to_h,
  persisted_message_kinds: turn.conversation.messages.map(&:kind),
  events: events.map(&:type)
)
