# frozen_string_literal: true

require_relative "test_helper"

class SpecialistTest < Minitest::Test
  def test_specialist_gets_explicit_task_and_own_tools_and_returns_full_report
    mutation = Class.new(TurnKit::Tool) do
      tool_name "mutate"
      def call(**)
        raise "parent tool must not execute in specialist"
      end
    end
    report = "Recommendation with evidence\nDetailed source findings"
    child_client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "denied", name: "mutate", arguments: {}) ]),
      TurnKit::Result.new(text: report, output_data: { "sources" => [ "repo/path.rb" ] })
    )
    specialist = TurnKit::Agent.new(name: "oracle", model: "specialist-model", client: child_client, instructions: "Read-only advice", tools: [])
    parent_client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "delegate", name: "oracle", arguments: { task: "Check this specific invariant" }) ]),
      TurnKit::Result.new(text: "Parent response")
    )
    parent = TurnKit::Agent.new(name: "parent", client: parent_client, tools: [ mutation ], sub_agents: [ specialist ])

    run = parent.run("Private parent context not passed to specialist")

    assert run.completed?
    request = child_client.calls.first
    assert_equal "specialist-model", request.fetch(:model)
    assert_empty request.fetch(:tools)
    assert_includes request.fetch(:instructions), "Read-only advice"
    assert_includes request.fetch(:messages).to_json, "Check this specific invariant"
    refute_includes request.fetch(:messages).to_json, "Private parent context"
    assert_includes child_client.calls.last.fetch(:messages).to_json, "unknown tool: mutate"
    result = run.turn.tool_executions.first.result
    assert_equal "completed", result.fetch("status")
    assert_equal report, result.fetch("result")
    assert_equal({ "sources" => [ "repo/path.rb" ] }, result.fetch("output_data"))
    assert_includes parent_client.calls.last.fetch(:messages).to_json, "Detailed source findings"
  end
end
