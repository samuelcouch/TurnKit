# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/deep_research/agents"

class DeepResearchTest < Minitest::Test
  class ResearchClient < TurnKit::Client
    attr_reader :requests
    def initialize
      @steps = Hash.new(0)
      @requests = []
    end

    def self.ideas
      3.times.map { |i| { "title" => "Idea #{i}", "mechanism" => "Testable mechanism", "adjacent_inspiration" => "Adjacent field",
        "evidence_urls" => ["https://example.org/source"], "uncertainty" => "Needs testing", "experiment" => "Measure a small pilot" } }
    end

    def chat(**request)
      @requests << request
      id = request.fetch(:metadata).fetch(:turn_id)
      name = TurnKit.store.load_turn(id).fetch("agent_name")
      @steps[id] += 1
      step = @steps[id]
      tool, arguments = case name
      when "deep_research"
        case step
        when 1 then ["research_questions", { questions: %w[Why? How? Evidence?], hypotheses: %w[Access Information] }]
        when 2 then ["launch_agent", { agent_name: "deep_adjacent", task: "Adjacent mechanisms", callback: false }]
        when 3 then ["deep_evidence", { task: "Direct evidence" }]
        when 4
          adjacent = TurnKit.store.list_turns(root_turn_id: id).find { |row| row["agent_name"] == "deep_adjacent" }
          ["wait_for", { turn_ids: [adjacent.fetch("id")] }]
        when 5 then ["deep_skeptic", { task: "Critique ideas with this evidence" }]
        when 6, 11 then ["submit_research", { summary: "Research report", open_questions: ["Will it work?"] }]
        when 7..9 then ["record_idea", self.class.ideas.fetch(step - 7).merge("slot" => step - 6)]
        when 10 then ["record_idea", self.class.ideas.first.merge("slot" => 1, "title" => "Revised idea")]
        end
      when "deep_evidence", "deep_adjacent"
        case step
        when 1 then ["web_search", { objective: name, search_queries: [name] }]
        when 2 then ["read_sources", { urls: ["https://example.org/source"], objective: name }]
        end
      end
      tool ? TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: "#{name}-#{step}", name: tool, arguments: arguments)]) : TurnKit::Result.new(text: "Source-backed research or critique")
    end
  end

  def test_background_research_uses_independent_branch_join_review_and_json
    jobs = Queue.new
    TurnKit.job_dispatcher = ->(id) { jobs << id }
    web = Object.new
    web.define_singleton_method(:search) { |**| { "results" => [{ "url" => "https://example.org/source" }] } }
    web.define_singleton_method(:read_pages) { |**| { "results" => [{ "url" => "https://example.org/source", "excerpts" => ["Evidence"] }] } }
    client = ResearchClient.new
    agent = TurnKit.register(DeepResearch.build(model: "test-model", client: client, web: web))
    assert_equal 10.0, agent.max_spend
    assert_equal 60, agent.max_iterations
    assert_equal 64, agent.max_tool_executions
    assert_equal 1200, agent.timeout
    run = agent.run("Research libraries", async: true).perform_later
    100.times do
      break if run.reload.completed? || jobs.empty?
      TurnKit::Background.perform(jobs.pop)
    end
    assert run.reload.completed?, run.error.inspect
    report = JSON.parse(run.output_text)
    assert_equal 3, report.fetch("ideas").length
    assert_equal "Revised idea", report.fetch("ideas").first.fetch("title")
    assert run.tool_executions.any? { |execution| execution.tool_name == "submit_research" && execution.failed? }
    assert_equal %w[deep_adjacent deep_evidence deep_skeptic], report.fetch("research_memos").map { |memo| memo["agent"] }.sort
    assert_equal 3, run.child_turn_records.length
    assert_equal 4, run.turn_records.map { |row| row["conversation_id"] }.uniq.length
    assert client.requests.all? { |request| request[:thinking] == { effort: "high" } }
    assert_equal 2, run.tool_executions.count { |execution| execution.tool_name == "web_search" && execution.completed? }
    assert run.tool_executions.any? { |execution| execution.tool_name == "wait_for" && execution.completed? }
    idea = ResearchClient.ideas.first.merge("evidence_urls" => ["https://invented.example/source"], "slot" => 1)
    context = TurnKit::ToolContext.new(turn: run.turn, execution: run.tool_executions.last)
    error = assert_raises(TurnKit::ToolError) { DeepResearch::RecordIdea.new.call(**idea.transform_keys(&:to_sym), context: context) }
    assert_includes error.message, "https://example.org/source"
  ensure
    TurnKit.job_dispatcher = nil
  end

  def test_research_questions_and_source_read_fail_loudly
    assert_raises(TurnKit::ToolError) { DeepResearch::ResearchQuestions.new.call(questions: ["Why?"], hypotheses: [], context: nil) }
    web = Object.new
    web.define_singleton_method(:read_pages) { |**| { "results" => [] } }
    assert_raises(TurnKit::ToolError) { DeepResearch::ReadSources.new(web).call(urls: ["https://example.org"], objective: "research", context: nil) }
  end
end
