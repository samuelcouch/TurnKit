# frozen_string_literal: true

require_relative "test_helper"

class ToolTest < Minitest::Test
  def test_terminal_tool_macro_marks_tool_as_turn_ending
    klass = Class.new(TurnKit::Tool) do
      tool_name "save_note"
      terminal! { |result| "Saved #{result.fetch("id")}." }

      def call(context:)
        { "id" => "note_1" }
      end
    end

    assert klass.ends_turn?
    assert_equal "Saved note_1.", klass.completion_message({ "id" => "note_1" })
  end
  def test_agent_enforces_per_tool_execution_limits
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "status_tool", arguments: { id: "st_1" }) ]),
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_2", name: "status_tool", arguments: { id: "st_2" }) ])
    )
    agent = TurnKit::Agent.new(
      name: "helper",
      client: client,
      tools: [ StatusTool ],
      max_iterations: 4,
      max_tool_executions_by_name: { "status_tool" => 1 }
    )

    run = agent.run("Check twice")

    assert run.failed?
    assert_includes run.error.fetch("message"), "maximum executions reached for tool status_tool"
    assert_equal [ "completed", "failed" ], run.tool_executions.map(&:status)
    assert_equal true, run.tool_executions.last.error.fetch("details").fetch("budget_denied")
  end
  def test_workflow_passes_per_tool_execution_limits
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "status_tool", arguments: { id: "st_1" }) ]),
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_2", name: "status_tool", arguments: { id: "st_2" }) ])
    )
    workflow = TurnKit::Agent.new(
      orchestrator: true,
      name: "helper",
      client: client,
      tools: [ StatusTool ],
      max_iterations: 4,
      max_tool_executions_by_name: { status_tool: 1 }
    )

    run = workflow.run("Check twice")

    assert run.failed?
    assert_includes run.error.fetch("message"), "maximum executions reached for tool status_tool"
    assert_equal [ "completed", "failed" ], run.tool_executions.map(&:status)
    assert_equal true, run.tool_executions.last.error.fetch("details").fetch("budget_denied")
  end
  def test_tool_argument_validation_reports_schema_errors
    assert_raises(TurnKit::ToolValidationError) { StatusTool.validate_arguments({}) }
    assert_raises(TurnKit::ToolValidationError) { StatusTool.validate_arguments("id" => 1) }
    assert_raises(TurnKit::ToolValidationError) { StatusTool.validate_arguments("id" => "st_1", "extra" => true) }
    assert_equal({ "id" => "st_1" }, StatusTool.validate_arguments("id" => "st_1"))
  end
  def test_invalid_tool_call_json_fails_tool_execution_without_calling_tool
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "status_tool", arguments: "{") ]),
      TurnKit::Result.new(text: "recovered")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ StatusTool ])

    turn = agent.conversation.ask("Use the tool")

    execution = turn.tool_executions.first
    assert execution.failed?
    assert_equal "invalid JSON arguments", execution.error.fetch("message")
    assert_equal "recovered", turn.output_text
  end
  def test_tool_instances_can_inject_dependencies
    lookup = LookupClient.new("st_1" => { "status" => "ok" })
    tool = InjectedLookupTool.new(client: lookup)
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "injected_lookup", arguments: { id: "st_1" }) ]),
      TurnKit::Result.new(text: "looked up")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [tool])

    turn = agent.conversation.ask("Look it up")

    assert turn.completed?
    assert_equal [ "st_1" ], lookup.requests
    assert_equal [ "injected_lookup" ], client.calls.first.fetch(:tools).map(&:tool_name)
    assert_equal "ok", turn.tool_executions.first.result.fetch("status")
  end
  def test_tool_classes_with_constructor_dependencies_report_actionable_error
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "injected_lookup", arguments: { id: "st_1" }) ]),
      TurnKit::Result.new(text: "recovered")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [InjectedLookupTool])

    turn = agent.conversation.ask("Look it up")

    execution = turn.tool_executions.first
    assert execution.failed?
    assert_includes execution.error.fetch("message"), "register an instance instead"
  end
  def test_agent_rejects_non_tool_entries
    error = assert_raises(ArgumentError) do
      TurnKit::Agent.new(name: "helper", tools: [Object.new])
    end

    assert_includes error.message, "TurnKit::Tool classes or instances"
  end
  def test_terminal_tool_completes_turn
    result = TurnKit::Result.new(
      text: "",
      tool_calls: [ TurnKit::ToolCall.new(id: "call_1", name: "save_report", arguments: { title: "T", body: "B" }) ]
    )
    client = FakeClient.new(result)
    agent = TurnKit::Agent.new(name: "writer", client: client, tools: [ SaveReport ])

    turn = agent.conversation.ask("Save it")

    assert turn.completed?
    assert_equal "Saved rep_1.", turn.output_text
    execution = turn.tool_executions.first
    assert execution.completed?
    assert_equal "save_report", execution.tool_name
    assert_equal "rep_1", execution.result.fetch("report_id")
  end
  def test_hash_with_error_key_is_successful_tool_data
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_error", name: "error_payload") ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ ErrorPayloadTool ])

    turn = agent.conversation.ask("run")

    execution = turn.tool_executions.first
    assert turn.completed?
    assert execution.completed?
    assert_equal "ordinary data", execution.result.fetch("error")
  end
  def test_tool_exceptions_are_failed_tool_executions
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_raise", name: "raising_tool") ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ RaisingTool ])

    turn = agent.conversation.ask("run")

    execution = turn.tool_executions.first
    assert turn.completed?
    assert execution.failed?
    assert_equal "boom", execution.error.fetch("message")
  end
  def test_tool_execution_receives_tool_context
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_context", name: "context_checking_tool") ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ ContextCheckingTool ])

    turn = agent.conversation.ask("run")

    assert turn.completed?
    assert turn.tool_executions.first.completed?
  end
  def test_tool_parameter_named_context_is_reserved
    error = assert_raises(ArgumentError) do
      Class.new(TurnKit::Tool) do
        tool_name "bad_tool"
        parameter :context, :string
      end
    end
    assert_includes error.message, "context is a reserved parameter name"
  end
  def test_terminal_tool_skips_sibling_calls_with_tool_results
    client = FakeClient.new(TurnKit::Result.new(tool_calls: [
      TurnKit::ToolCall.new(id: "save_1", name: "save_report", arguments: { title: "T", body: "B" }),
      TurnKit::ToolCall.new(id: "status_1", name: "status_tool", arguments: { id: "st_1" })
    ]))
    agent = TurnKit::Agent.new(name: "writer", client: client, tools: [ SaveReport, StatusTool ])

    turn = agent.conversation.ask("Save it")

    assert turn.completed?
    assert_equal [ "completed", "cancelled" ], turn.tool_executions.map(&:status)
    projected = TurnKit::MessageProjection.for(turn.conversation.messages)
    assistant_call_ids = projected.flat_map { |message| Array(message[:tool_calls]).map { |call| call.fetch("id") } }
    result_ids = projected.filter_map { |message| message[:tool_call_id] if message[:role] == :tool }
    assert_equal assistant_call_ids.sort, result_ids.sort
  end
end
