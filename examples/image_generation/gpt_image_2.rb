# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "fileutils"
require "json"
require "tmpdir"
require "turnkit"
require_relative "../shared/model_registry"

MODEL = ENV.fetch("TURNKIT_IMAGE_MODEL", "gpt-image-2")
PROVIDER = :openai
TurnKitExamples.prepare_model(MODEL)

output_path = File.expand_path(ARGV[0] || "turnkit-gpt-image-2.png", Dir.tmpdir)
prompt = <<~PROMPT.strip
  Create a cinematic landscape editorial header image for a Ruby workflow
  runtime called TurnKit. Show durable orchestration, audit trails, and image
  generation as clean abstract visual metaphors. No text or logos.
PROMPT

events = []
agent = TurnKit::Agent.new(
  name: "image_smoke_test",
  client: TurnKit::Adapters::RubyLLM.new,
  max_spend: 0.25,
  on_event: ->(event) { events << event }
)

turn = agent.run("Generate a landscape header image with #{MODEL}.", async: true).turn
image = turn.paint(
  prompt,
  model: MODEL,
  provider: PROVIDER,
  size: "1536x1024",
  params: { output_format: "png" },
  metadata: { example: "image_generation/gpt_image_2" }
)

FileUtils.mkdir_p(File.dirname(output_path))
File.binwrite(output_path, image.to_blob)

puts JSON.pretty_generate(
  status: turn.reload.status,
  model: image.model,
  provider: image.provider,
  mime_type: image.mime_type,
  bytes: File.size(output_path),
  output: output_path,
  usage: turn.usage.to_h,
  cost: turn.cost.to_h,
  persisted_message_kinds: turn.conversation.messages.map(&:kind),
  events: events.map(&:type)
)
