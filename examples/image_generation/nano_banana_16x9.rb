# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "base64"
require "fileutils"
require "open3"
require "tmpdir"
require "turnkit"

class GenerateImageClient < TurnKit::Client
  def initialize(command: "generate-image", output_path:)
    @command = command
    @output_path = output_path
  end

  def validate!(model:)
    raise TurnKit::ModelAccessError, "#{@command} was not found on PATH" unless system("which", @command, out: File::NULL)

    true
  end

  def paint(prompt:, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: nil, on_event: nil)
    FileUtils.mkdir_p(File.dirname(@output_path))
    command = [
      @command,
      "--provider", (provider || :gemini).to_s,
      "--model", model,
      "--aspect-ratio", params.fetch(:aspect_ratio, "16:9"),
      "--image-size", params.fetch(:image_size, "1K"),
      "--prompt", prompt,
      "--output", @output_path
    ]
    stdout, stderr, status = Open3.capture3(*command)
    raise TurnKit::Error, [ stdout, stderr ].reject(&:empty?).join("\n") unless status.success?

    image = TurnKit::ImageResult.new(
      data: Base64.strict_encode64(File.binread(@output_path)),
      mime_type: "image/jpeg",
      model: model,
      provider: provider.to_s,
      params: params.merge(aspect_ratio: "16:9", image_size: "1K"),
      metadata: (metadata || {}).merge(output_path: @output_path, cli: stdout.strip)
    )
    TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], model: model, output_data: { "type" => "image", "images" => [ image.to_h ] })
  end
end

output_path = File.expand_path(ARGV[0] || "turnkit-nano-banana-pro-16x9.jpg", Dir.tmpdir)
prompt = <<~PROMPT.strip
  Create a cinematic 16:9 editorial header image for a Ruby workflow runtime
  called TurnKit. Show durable orchestration, audit trails, and image generation
  as clean abstract visual metaphors. No text or logos.
PROMPT

events = []
agent = TurnKit::Agent.new(
  name: "image_smoke_test",
  client: GenerateImageClient.new(output_path: output_path),
  on_event: ->(event) { events << event }
)

turn = agent.run("Generate a 16:9 header image with nano-banana-pro.", async: true).turn
image = turn.paint(
  prompt,
  model: "nano-banana-pro",
  provider: :gemini,
  params: { aspect_ratio: "16:9", image_size: "1K" },
  metadata: { example: "image_generation/nano_banana_16x9" }
)

puts "status: #{turn.reload.status}"
puts "model: #{image.model}"
puts "provider: #{image.provider}"
puts "mime_type: #{image.mime_type}"
puts "bytes: #{image.to_blob.bytesize}"
puts "output: #{output_path}"
puts "events: #{events.map(&:type).join(", ")}"
