# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "turnkit"

class AccountLookup < TurnKit::Tool
  tool_name "account_lookup"
  description "Look up account facts from the CRM."
  parameter :account_id, :string, required: true

  def call(account_id:, context:)
    {
      account_id: account_id,
      plan: "enterprise",
      renewal_days: 21,
      open_tickets: 2
    }
  end
end

class WorkflowClient < TurnKit::Client
  attr_reader :calls

  def initialize
    @calls = []
  end

  def chat(model:, messages:, tools:, instructions:, **)
    @calls << { model: model, messages: messages, tools: tools, instructions: instructions }

    if calls.length == 1
      TurnKit::Result.new(
        tool_calls: [TurnKit::ToolCall.new(id: "call_1", name: "account_lookup", arguments: { account_id: "acct_123" })],
        model: model
      )
    else
      TurnKit::Result.new(
        text: "Renewal risk: medium. Enterprise renewal is 21 days away with 2 open tickets; prioritize support follow-up before outreach.",
        model: model
      )
    end
  end
end

renewal_workflow = TurnKit::Skill.from_file(File.join(__dir__, "skills", "renewal_risk_review.md"))

client = WorkflowClient.new
workflow = TurnKit::Workflow.new(
  name: "renewal_risk_review",
  instructions: "Review renewal risk using CRM facts before making a recommendation.",
  skills: [renewal_workflow],
  tools: [AccountLookup],
  client: client,
  max_iterations: 4,
  max_tool_executions: 4,
  max_spend: 0.25
)

run = workflow.run(
  "Review renewal risk for this account.",
  input: { account_id: "acct_123" }
)

puts "Use TurnKit::Workflow when a task becomes a reusable production capability."
puts
puts "workflow_name: #{workflow.name}"
puts "run_id: #{run.id}"
puts "status: #{run.status}"
puts "output: #{run.output}"
puts "steps: #{run.steps}"
puts "tool_calls: #{run.tool_calls.map(&:tool_name).join(", ")}"
puts "model_calls: #{client.calls.length}"
puts "has_workflow_skill: #{client.calls.first.fetch(:instructions).include?("renewal_risk_review") ? "yes" : "no"}"
