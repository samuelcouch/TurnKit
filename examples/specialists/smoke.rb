# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "turnkit"
require "logger"
require_relative "../shared/model_registry"

mode = ARGV.fetch(0, "oracle")
model = ENV.fetch("TURNKIT_MODEL", "claude-sonnet-5")
RubyLLM.configure { |config| config.logger = Logger.new($stderr, level: Logger::WARN) }
TurnKitExamples.prepare_model(model)
options = { model: model, thinking: { effort: "high" }, max_spend: 0.50, max_iterations: 6, max_tool_executions: 4, timeout: 180 }

agent, task, expected = case mode
when "oracle"
  [TurnKit::Specialists.oracle(**options, root: File.expand_path("../../docs", __dir__)),
   "Read runtime-hardening.md. In three concise bullets explain what cancellation can and cannot guarantee. Cite the file.", "read_file"]
when "librarian"
  [TurnKit::Specialists.librarian(**options, repository: "ruby/json"),
   "Read README.md in the configured repository and explain its purpose in two short sentences with the source URL. Use the file operation.", "github_repository_read"]
when "painter"
  # This explicit CLI command grants generation for this one demonstration.
  [TurnKit::Specialists.painter(**options, image_model: "gpt-image-2", params: { quality: "low" },
     authorization: ->(_request, context:) { context.principal == "image-demo" }),
   "Generate one simple flat illustration of an orange pear on a pale blue background, no text.", "paint_image"]
else
  abort "Usage: bundle exec ruby examples/specialists/smoke.rb oracle|librarian|painter"
end

run = agent.run(task, principal: "image-demo")
raise "Specialist failed: #{run.error.inspect}" unless run.completed?
raise "Expected #{expected} to complete" unless run.tool_executions.any? { |execution| execution.tool_name == expected && execution.completed? }
result = { mode: mode, status: run.status, model: model, cost: run.cost.total, result: run.output_text,
  tools: run.tool_executions.map { |execution| { name: execution.tool_name, status: execution.status } } }
if mode == "painter"
  reference = JSON.parse(run.output_text)
  image_message = run.messages.find { |message| message.id == reference.fetch("image_message_id") }
  raise "Missing persisted image" unless image_message&.image?
  image = TurnKit::ImageResult.from_h(image_message.content.find { |part| part["type"] == "image" })
  if ENV["TURNKIT_IMAGE_OUTPUT"]
    File.binwrite(ENV.fetch("TURNKIT_IMAGE_OUTPUT"), image.to_blob)
    result[:image_file] = ENV.fetch("TURNKIT_IMAGE_OUTPUT")
  end
end
puts JSON.pretty_generate(result)
