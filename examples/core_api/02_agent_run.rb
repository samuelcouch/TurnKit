# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "turnkit"

class ClassificationClient < TurnKit::Client
  attr_reader :calls

  def initialize
    @calls = []
  end

  def chat(model:, messages:, tools:, instructions:, output_schema: nil, **)
    @calls << { model: model, messages: messages, tools: tools, instructions: instructions, output_schema: output_schema }

    data = {
      "priority" => "high",
      "route" => "sales",
      "reason" => "Enterprise company with urgent implementation timeline."
    }

    TurnKit::Result.new(text: data.to_json, output_data: data, model: model)
  end
end

schema = {
  type: "object",
  properties: {
    priority: { type: "string" },
    route: { type: "string" },
    reason: { type: "string" }
  },
  required: ["priority", "route", "reason"]
}

client = ClassificationClient.new
agent = TurnKit::Agent.new(
  name: "lead_classifier",
  instructions: "Classify inbound leads for routing.",
  output_schema: schema,
  client: client
)

run = agent.run(
  "Classify this lead.",
  input: { company: "Acme", employees: 1_200, note: "Need implementation this month" }
)

puts "Use Agent#run when your app needs one bounded result now."
puts
puts "run_id: #{run.id}"
puts "status: #{run.status}"
puts "output_data: #{run.output_data.inspect}"
puts "stored_messages: #{run.messages.length}"
puts "model_calls: #{client.calls.length}"
puts "task_prompt: #{client.calls.first.fetch(:instructions).include?("executing an application task") ? "yes" : "no"}"
