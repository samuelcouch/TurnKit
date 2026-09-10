# frozen_string_literal: true

require_relative "app"

rows = InteractiveValidation::Evidence.order(:id).map { |row| { id: row.id, kind: row.kind, turn_id: row.turn_uid, data: row.data } }
providers = rows.select { |row| row[:kind] == "provider" }
metrics = providers.map do |row|
  usage = row[:data].fetch("usage")
  cached = (usage["cachedContentTokenCount"] || usage["cache_read_input_tokens"] || usage.dig("input_tokens_details", "cached_tokens")).to_i
  writes = (usage["cache_creation_input_tokens"] || usage.dig("input_tokens_details", "cache_write_tokens")).to_i
  reasoning = (usage["thoughtsTokenCount"] || usage.dig("output_tokens_details", "reasoning_tokens") || usage.dig("output_tokens_details", "thinking_tokens")).to_i
  input = usage["promptTokenCount"] || usage.fetch("input_tokens")
  input += cached + writes if row[:data]["provider"] == "anthropic"
  output = usage["output_tokens"] || usage["candidatesTokenCount"].to_i + reasoning
  normalized = TurnKit::Usage.new(input_tokens: input - cached - writes, output_tokens: output - reasoning,
    cached_tokens: cached, cache_write_tokens: writes, thinking_tokens: reasoning, cost: row[:data]["estimated_cost_usd"])
  { adapter: row[:data]["adapter"] || "native_prototype",
    counts: { "input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output,
      "cached_tokens" => cached, "cache_write_tokens" => writes, "reasoning_tokens" => reasoning },
    cost: TurnKit::Cost.from_usage(normalized, model: row[:data].fetch("model")).total }
end
summarize = lambda do |requests|
  totals = requests.each_with_object(Hash.new(0)) { |request, sum| request[:counts].each { |key, value| sum[key] += value } }
  costs = requests.map { |request| request[:cost] }
  { provider_requests: requests.length, provider_totals: totals, estimated_provider_usd: costs.any?(&:nil?) ? nil : costs.sum }
end
puts JSON.pretty_generate({
  exported_at: Time.now.utc.iso8601,
  versions: { ruby: RUBY_VERSION, rails: Rails.version, active_record: ActiveRecord.version.to_s,
    active_job: ActiveJob.version.to_s, sidekiq: Sidekiq::VERSION,
    ruby_llm: RubyLLM::VERSION,
    postgres: ActiveRecord::Base.connection.select_value("SHOW server_version") },
  **summarize.call(metrics),
  provider_adapters: providers.group_by { |row| row[:data]["adapter"] || "native_prototype" }.transform_values(&:length),
  campaigns: metrics.group_by { |row| row[:adapter] }.transform_values { |requests| summarize.call(requests) },
  evidence: rows,
  turns: TurnKit.store.list_submitted_turns.map do |row|
    turn = TurnKit.load_turn(row.fetch("id"))
    { turn_id: turn.id, conversation_id: turn.conversation.id, parent_turn_id: turn.parent_turn_id,
      control: turn.control_state, output: turn.output_text, usage: turn.usage.to_h,
      tools: turn.tool_executions.map { |execution| { id: execution.id, status: execution.status, result: execution.result } },
      messages: turn.conversation.messages_after(0).map(&:to_h) }
  end
})
