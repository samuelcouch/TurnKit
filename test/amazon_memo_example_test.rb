# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/amazon_memo_writer/amazon_memo_writer"

class FakeAmazonMemoResearchClient
  def search(objective:, search_queries:)
    {
      "objective" => objective,
      "search_queries" => search_queries,
      "results" => [
        { "url" => "https://example.com/race-photo-discovery", "title" => "Race Photo Discovery Study", "excerpt" => "Bib-number search reduces manual lookup requests." },
        { "url" => "https://example.com/event-check-in-workload", "title" => "Event Staff Workload Notes", "excerpt" => "Accurate photo matching cuts back-and-forth for event teams." }
      ]
    }
  end

  def read_page(url:, objective:)
    {
      "url" => url,
      "objective" => objective,
      "content" => case url
      when "https://example.com/race-photo-discovery"
        "Race organizers report fewer manual lookup requests when attendees can search by bib number."
      when "https://example.com/event-check-in-workload"
        "Clear attendee instructions and accurate photo matching reduce back-and-forth for organizers and photographers."
      else
        ""
      end
    }
  end
end

class AmazonMemoExampleTest < Minitest::Test
  def test_amazon_memo_example_finalizes_with_structured_terminal_tool
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "search_1", name: "web_search", arguments: { objective: "research", search_queries: [ "race photo bib search" ] }) ]),
      TurnKit::Result.new(tool_calls: [
        TurnKit::ToolCall.new(id: "read_1", name: "read_web_page", arguments: { url: "https://example.com/race-photo-discovery", objective: "extract photo discovery evidence" }),
        TurnKit::ToolCall.new(id: "read_2", name: "read_web_page", arguments: { url: "https://example.com/event-check-in-workload", objective: "extract organizer workload evidence" })
      ]),
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "submit_1", name: "submit_amazon_memo", arguments: {
        title: "Add Bib Number Search for Race Photo Galleries",
        author: "TurnKit Memo Bot",
        date: "2026-06-09",
        tldr: "Launch bib-number search so race attendees can find photos faster and organizers handle fewer lookup questions.",
        customer_problem: "Event organizers and photographers lose time when attendees cannot find their photos and ask staff for help after the event.",
        current_evidence: "Read sources say bib-number search reduces manual lookup requests and accurate photo matching cuts back-and-forth for event teams.",
        recommendation: "Launch a race-event pilot that lets attendees search galleries by bib number and gives organizers clear instructions to share.",
        risks_and_open_questions: [
          "The main risk is inaccurate photo matching for covered or missing bib numbers.",
          "The largest open question is which race formats should join the pilot first."
        ],
        next_steps: [
          "Choose two race photographers for the pilot this week.",
          "Draft attendee instructions that explain how to search by bib number."
        ],
        sources: [ "https://example.com/race-photo-discovery", "https://example.com/event-check-in-workload" ]
      }) ]),
      TurnKit::Result.new(output_data: { "approved" => true, "violations" => [] }),
      TurnKit::Result.new(output_data: { "approved" => true, "violations" => [] })
    )
    workflow = AmazonMemoWriter.workflow(model: "test-model", client: client, parallel_client: FakeAmazonMemoResearchClient.new, semantic_audit: true)

    run = workflow.run("Write the memo")
    accuracy = AmazonMemoWriter.accuracy(run.output_text, run)

    assert run.completed?
    assert_equal 100.0, accuracy.fetch(:score)
    assert_equal 6, accuracy.fetch(:passed)
    assert_equal [ "web_search", "read_web_page", "read_web_page", "submit_amazon_memo" ], run.tool_executions.map(&:tool_name)
    assert_includes run.output_text, "Status: Draft"
    assert_includes run.output_text, "## TL;DR"
    assert_includes run.output_text, "## Recommendation"
    assert_includes run.output_text, "## Next Steps"
    assert_match(/^1\. The main risk is inaccurate photo matching/, run.output_text)
    assert_match(/^1\. Choose two race photographers/, run.output_text)
    assert_match(/^1\. https:\/\/example.com\/race-photo-discovery/, run.output_text)
    refute_includes run.output_text, "—"
    refute_match(/^\s*[-*]\s+/, run.output_text)
    assert_empty AmazonMemoWriter.format_policy(run.output_text)
  end
end
