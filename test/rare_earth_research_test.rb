# frozen_string_literal: true

require_relative "deep_research_test"
require_relative "../examples/deep_research/rare_earth"

class RareEarthResearchTest < Minitest::Test
  def test_access_block_is_not_evidence
    web = Object.new
    web.define_singleton_method(:read_pages) { |**| { "results" => [{ "url" => "https://example.org", "title" => "Robot Challenge Screen", "excerpts" => ["Verify you are human"] }] } }
    assert_raises(TurnKit::ToolError) { RareEarthResearch::ReadSources.new(web).call(urls: ["https://example.org"], objective: "Verify company", context: nil) }
  end

  class Client < DeepResearchTest::ResearchClient
    COMPANY = { name: "Example", ticker: "EX", exchange: "NYSE", exposure: "NdPr separation",
      verification: "IR dated 2026-09-01 verifies listing and exposure", downside: "If delayed, cash use rises",
      base: "If schedules hold, pilot work continues", upside: "If qualified, orders expand",
      uncertainty: "No guarantee", evidence_urls: ["https://example.org/source"] }.freeze
    POLICY = { name: "Example law", status: "enacted_law", analysis: "Dated primary evidence and limits", evidence_urls: ["https://example.org/source"] }.freeze
    def chat(**request)
      id = request.fetch(:metadata).fetch(:turn_id)
      return super unless TurnKit.store.load_turn(id).fetch("agent_name") == "rare_earth_research"
      @requests << request
      @steps[id] += 1
      tool, args = case @steps[id]
      when 1 then ["research_questions", { questions: %w[Law? Listings? Triggers?], hypotheses: %w[Support Constraints] }]
      when 2 then ["launch_agent", { agent_name: "deep_adjacent", task: "Companies", callback: false }]
      when 3 then ["deep_evidence", { task: "Policies" }]
      when 4
        adjacent = TurnKit.store.list_turns(root_turn_id: id).find { |row| row["agent_name"] == "deep_adjacent" }
        ["wait_for", { turn_ids: [adjacent.fetch("id")] }]
      when 5 then ["submit_research", { summary: "Premature", limitations: ["Gaps"] }]
      when 6 then ["deep_skeptic", { task: "Review report" }]
      when 7 then ["record_policy", POLICY]
      when 8 then ["record_company", COMPANY.merge(evidence_urls: ["https://invented.example"])]
      when 9 then ["record_company", COMPANY]
      when 10 then ["record_company", COMPANY.merge(uncertainty: "Revised uncertainty")]
      when 11 then ["submit_research", { summary: "Detailed report", limitations: ["Non-exhaustive"] }]
      end
      TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: "root-#{@steps[id]}", name: tool, arguments: args)])
    end
  end

  def test_report_orchestration_validation_and_rendering
    jobs = Queue.new
    TurnKit.job_dispatcher = ->(id) { jobs << id }
    web = Object.new
    web.define_singleton_method(:search) { |**| { "results" => [] } }
    web.define_singleton_method(:read_pages) { |**| { "results" => [{ "url" => "https://example.org/source", "excerpts" => ["Evidence"] }] } }
    client = Client.new
    agent = TurnKit.register(RareEarthResearch.build(model: "test-model", client: client, web: web, as_of: Date.new(2026, 9, 6)))
    run = agent.run(RareEarthResearch.topic(Date.new(2026, 9, 6)), async: true).perform_later
    100.times do
      break if run.reload.completed? || jobs.empty?
      TurnKit::Background.perform(jobs.pop)
    end
    assert run.reload.completed?, run.error.inspect
    report = JSON.parse(run.output_text)
    assert TurnKit::SchemaCheck.validate!(report, RareEarthResearch.report_schema)
    assert_raises(TurnKit::ToolValidationError) { TurnKit::SchemaCheck.validate!(report.except("companies"), RareEarthResearch.report_schema) }
    assert_equal "2026-12-05", report.fetch("horizon_end")
    assert_equal 1, report.fetch("companies").length
    assert_equal "Revised uncertainty", report.fetch("companies").first.fetch("uncertainty")
    assert_equal "enacted_law", report.fetch("policies").first.fetch("status")
    assert_equal 3, run.child_turn_records.count { |row| row["status"] == "completed" }
    assert client.requests.all? { |request| request[:thinking] == { effort: "high" } }
    assert_equal %w[record_company submit_research], run.tool_executions.select(&:failed?).map(&:tool_name).sort
    markdown = RareEarthResearch.markdown(report)
    assert_includes markdown, "NYSE: EX"
    assert_includes markdown, "**Downside:** If delayed"
    assert_includes markdown, "## Limitations"
    context = TurnKit::ToolContext.new(turn: run.turn, execution: run.tool_executions.last)
    assert_raises(TurnKit::ToolError) { RareEarthResearch::RecordCompany.new.call(**Client::COMPANY.merge(exchange: "OTC"), context: context) }
    assert_raises(TurnKit::ToolError) { RareEarthResearch::RecordCompany.new.call(**Client::COMPANY.merge(downside: ""), context: context) }
    assert_raises(TurnKit::ToolError) { RareEarthResearch::RecordPolicy.new.call(**Client::POLICY.merge(status: "rumor"), context: context) }
  ensure
    TurnKit.job_dispatcher = nil
  end
end
