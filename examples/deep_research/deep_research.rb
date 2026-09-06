# frozen_string_literal: true

# Reuse the reference app's Rails/PostgreSQL/Solid Queue boot and schema, not
# its fake research agents. Every agent below has an explicit live client.
ENV["TURNKIT_DEMO_DATABASE_URL"] ||= "postgresql:///turnkit_demo_deep"
require_relative "../durable_research/app"
require_relative "../shared/model_registry"
require_relative "agents"

TurnKit.on_event = nil
RubyLLM.configure { |config| config.logger = Rails.logger }
model = ENV.fetch("TURNKIT_MODEL", "claude-sonnet-5")
TurnKitExamples.prepare_model(model)
research = DeepResearch
if ENV["TURNKIT_RESEARCH_REPORT"] == "rare_earth"
  require_relative "rare_earth"
  research = RareEarthResearch
end
agent = TurnKit.register(research.build(model: model, max_spend: Float(ENV.fetch("TURNKIT_MAX_SPEND", "10.0"))))

if ARGV.first == "worker"
  ARGV.shift
  require_relative "../durable_research/jobs"
else
  topic = research == DeepResearch ? DeepResearch::DEFAULT_TOPIC : research.topic
  run = agent.run(ARGV.empty? ? topic : ARGV.join(" "), async: true).perform_later
  warn "Submitted deep research turn #{run.id}"
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1260
  until %w[completed failed cancelled].include?(run.reload.status)
    raise "Timed out waiting; persisted turn #{run.id} remains available for inspection/cancellation" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 1
  end
  raise "Research failed: #{run.error.inspect}" unless run.completed?
  raise "Research ended without validated submission" unless run.tool_executions.any? { |execution| execution.tool_name == "submit_research" && execution.completed? }
  report = JSON.parse(run.output_text)
  TurnKit::SchemaCheck.validate!(report, research.report_schema) if research.respond_to?(:report_schema)
  branches = run.child_turn_records.select { |row| %w[deep_evidence deep_adjacent].include?(row["agent_name"]) }
  overlap = branches.length == 2 && branches.map { |row| row.fetch("completed_at") }.min - branches.map { |row| row.fetch("started_at") }.max
  raise "Research branches did not overlap" unless overlap && overlap.positive?
  warn JSON.generate(turn_id: run.id, model: model, thinking: agent.thinking, status: run.status,
    model_cost: run.cost.total, tokens: run.usage.total_tokens, branch_execution_overlap_seconds: overlap,
    children: run.child_turn_records.map { |row| row.slice("id", "conversation_id", "agent_name", "status", "started_at", "completed_at") },
    tools: run.tool_executions.map { |execution| { name: execution.tool_name, status: execution.status } })
  puts JSON.pretty_generate(report)
  File.write(ENV.fetch("TURNKIT_REPORT_MARKDOWN"), research.markdown(report)) if research.respond_to?(:markdown) && ENV["TURNKIT_REPORT_MARKDOWN"]
end
