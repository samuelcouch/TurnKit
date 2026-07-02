# frozen_string_literal: true

require_relative "test_helper"

class OutputPolicyTest < Minitest::Test
  def test_check_output_policy_runs_user_defined_constraints
    no_em_dash = ->(output) do
      next if output.count("—").zero?

      { rule: "no_em_dash", message: "contains em dash", metadata: { count: output.count("—") } }
    end
    numbered_lists_only = ->(output) do
      lines = output.lines.each_with_index.filter_map { |line, index| index + 1 if line.match?(/^\s*[-*]\s+/) }
      next if lines.empty?

      { rule: "numbered_lists_only", message: "contains unordered list markers", metadata: { lines: lines } }
    end

    result = TurnKit.check_output_policy(
      "1. Recommendation\n- unordered item — fix this\n",
      constraints: [ no_em_dash, numbered_lists_only ]
    )

    refute result.clean?
    assert_equal [ "no_em_dash", "numbered_lists_only" ], result.violations.map(&:rule)
    assert_equal 1, result.violations[0].metadata.fetch(:count)
    assert_equal [ 2 ], result.violations[1].metadata.fetch(:lines)
  end
  def test_check_output_policy_supports_structured_output_constraints
    requires_recommendation = ->(output) do
      next if output.fetch("recommendation", "").length.positive?

      { rule: "recommendation_required", message: "missing recommendation" }
    end
    requires_sources = Class.new do
      def check(output)
        return if output.fetch("sources", []).length >= 2

        TurnKit::OutputAudit::Violation.new(
          rule: "source_count",
          message: "needs at least two sources",
          metadata: { count: output.fetch("sources", []).length }
        )
      end
    end.new

    result = TurnKit.check_output_policy(
      { "recommendation" => "Pilot", "sources" => [ "S1" ] },
      constraints: [ requires_recommendation, requires_sources ]
    )

    refute result.clean?
    assert_equal [ "source_count" ], result.violations.map(&:rule)
    assert_equal({ "clean" => false, "violations" => [ { "rule" => "source_count", "message" => "needs at least two sources", "metadata" => { count: 1 } } ] }, result.to_h)
  end
  def test_check_output_policy_accepts_clean_output
    result = TurnKit.check_output_policy(
      "1. Recommendation\n   1. Pilot with guardrails.\n",
      constraints: [ ->(output) { "missing recommendation" unless output.include?("Recommendation") } ]
    )

    assert result.clean?
    assert_empty result.messages
    assert_equal({ "clean" => true, "violations" => [] }, result.to_h)
  end
  def test_agent_policy_audit_report_mode_completes_and_records_violations
    audit = ->(output, turn:) do
      assert_instance_of TurnKit::Turn, turn
      next if output.include?("Recommendation")

      { rule: "recommendation_required", message: "missing recommendation" }
    end
    client = FakeClient.new(TurnKit::Result.new(text: "Draft only"))
    agent = TurnKit::Agent.new(name: "writer", client: client, output_policy: audit, output_policy_mode: :report)

    run = agent.run("Write memo")

    assert run.completed?
    refute run.policy_clean?
    assert_equal "recommendation_required", run.policy_audit.fetch("violations").first.fetch("rule")
    assert_equal "Draft only", run.output_text
  end
  def test_agent_policy_audit_fail_mode_fails_turn_after_recording_output
    audit = ->(_output) { { rule: "approved_output", message: "not approved" } }
    client = FakeClient.new(TurnKit::Result.new(text: "bad output"))
    agent = TurnKit::Agent.new(name: "writer", client: client, output_policy: audit, output_policy_mode: :fail)

    run = agent.run("Write memo")

    assert run.failed?
    assert_equal "bad output", run.output_text
    refute run.policy_clean?
    assert_equal "TurnKit::OutputAudit", run.error.fetch("class")
    assert_equal "approved_output", run.error.fetch("policy_audit").fetch("violations").first.fetch("rule")
  end
  def test_workflow_passes_policy_audit_to_agent
    audit = ->(_output) { "missing approval" }
    client = FakeClient.new(TurnKit::Result.new(text: "finished"))
    workflow = TurnKit::Agent.new(orchestrator: true, name: "research", client: client, output_policy: audit, output_policy_mode: :fail)

    run = workflow.run("Create a brief")

    assert run.failed?
    assert_equal "output_constraint", run.policy_audit.fetch("violations").first.fetch("rule")
  end
  def test_output_policy_from_file_runs_with_its_own_model
    file = Tempfile.new([ "memo_policy", ".md" ])
    file.write("Approve only outputs that include a recommendation.")
    file.close
    audit_client = FakeClient.new(TurnKit::Result.new(output_data: {
      "approved" => false,
      "violations" => [ { "rule" => "recommendation", "message" => "missing recommendation" } ]
    }))
    policy = TurnKit::OutputPolicy.from_file(file.path, model: "audit-model", client: audit_client)

    result = TurnKit.check_output_policy("Draft", constraints: [ policy ])

    refute result.clean?
    assert_equal "recommendation", result.violations.first.rule
    assert_equal "audit-model", audit_client.calls.first.fetch(:model)
    assert_includes audit_client.calls.first.fetch(:instructions), "Approve only outputs"
  ensure
    file&.unlink
  end
  def test_agent_output_policy_path_uses_policy_model
    file = Tempfile.new([ "memo_policy", ".md" ])
    file.write("Approve only outputs that include a recommendation.")
    file.close
    audit_client = FakeClient.new(TurnKit::Result.new(output_data: { "approved" => true, "violations" => [] }))
    agent = TurnKit::Agent.new(
      name: "writer",
      client: FakeClient.new(TurnKit::Result.new(text: "Recommendation: pilot")),
      output_policy: file.path,
      output_policy_model: "audit-model",
      output_policy_mode: :fail
    )
    agent.output_policy.instance_variable_set(:@client, audit_client)

    run = agent.run("Write memo")

    assert run.completed?
    assert run.policy_clean?
    assert_equal "audit-model", audit_client.calls.first.fetch(:model)
  ensure
    file&.unlink
  end
  def test_output_policy_path_uses_global_model_and_thinking_defaults
    file = Tempfile.new([ "memo_policy", ".md" ])
    file.write("Approve all outputs.")
    file.close
    TurnKit.output_policy_model = "audit-default"
    TurnKit.output_policy_thinking = { effort: :low }
    audit_client = FakeClient.new(TurnKit::Result.new(output_data: { "approved" => true, "violations" => [] }))
    agent = TurnKit::Agent.new(
      name: "writer",
      client: FakeClient.new(TurnKit::Result.new(text: "Recommendation: pilot")),
      output_policy: file.path
    )
    agent.output_policy.instance_variable_set(:@client, audit_client)

    run = agent.run("Write memo")

    assert run.completed?
    assert_equal "audit-default", audit_client.calls.first.fetch(:model)
    assert_equal({ effort: :low }, audit_client.calls.first.fetch(:thinking))
  ensure
    file&.unlink
  end
  def test_agent_output_policy_accepts_pathname_and_plain_objects
    file = Tempfile.new([ "memo_policy", ".txt" ])
    file.write("Approve all outputs.")
    file.close
    object_policy = Class.new do
      def check(output)
        return if output.include?("Recommendation")

        { rule: "recommendation", message: "missing recommendation" }
      end
    end.new

    agent = TurnKit::Agent.new(name: "writer", output_policy: [ Pathname(file.path), object_policy ])

    assert_equal 2, agent.effective_output_policy.length
    assert_instance_of TurnKit::OutputPolicy, agent.effective_output_policy.first
    assert_same object_policy, agent.effective_output_policy.last
  ensure
    file&.unlink
  end
  def test_agent_output_policy_rejects_ambiguous_strings
    assert_raises(ArgumentError) do
      TurnKit::Agent.new(name: "writer", output_policy: "use numbered lists")
    end
  end
  def test_workflow_passes_output_policy_to_agent
    policy = ->(_output) { { rule: "approved_output", message: "not approved" } }
    client = FakeClient.new(TurnKit::Result.new(text: "finished"))
    workflow = TurnKit::Agent.new(orchestrator: true, name: "research", client: client, output_policy: policy, output_policy_mode: :fail)

    run = workflow.run("Create a brief")

    assert run.failed?
    assert_equal "approved_output", run.policy_audit.fetch("violations").first.fetch("rule")
  end
  def test_workflow_output_policy_path_uses_workflow_client_by_default
    file = Tempfile.new([ "memo_policy", ".md" ])
    file.write("Approve all outputs.")
    file.close
    workflow_client = FakeClient.new(
      TurnKit::Result.new(text: "Recommendation: pilot"),
      TurnKit::Result.new(output_data: { "approved" => true, "violations" => [] })
    )
    TurnKit.client = FakeClient.new(TurnKit::Result.new(output_data: { "approved" => false, "violations" => [ { "rule" => "wrong_client", "message" => "wrong client" } ] }))
    workflow = TurnKit::Agent.new(orchestrator: true, name: "research", client: workflow_client, output_policy: file.path, output_policy_mode: :fail)

    run = workflow.run("Create a brief")

    assert run.completed?
    assert run.policy_clean?
    assert_equal 2, workflow_client.calls.length
    assert_empty TurnKit.client.calls
    assert_equal [], workflow_client.calls.last.fetch(:tools)
  ensure
    file&.unlink
  end
  def test_output_policy_accepts_fenced_json_from_auditor_model
    audit_client = FakeClient.new(TurnKit::Result.new(text: <<~TEXT))
      ```json
      {"approved":false,"violations":[{"rule":"format","message":"missing heading"}]}
      ```
    TEXT
    policy = TurnKit::OutputPolicy.new(content: "Require heading.", client: audit_client)

    result = TurnKit.check_output_policy("Draft", constraints: [policy])

    refute result.clean?
    assert_equal "format", result.violations.first.rule
  end
  def test_output_policy_model_usage_is_counted_on_parent_run
    client = FakeClient.new(
      TurnKit::Result.new(text: "Draft", usage: TurnKit::Usage.new(input_tokens: 10, output_tokens: 10, cost: 0.01)),
      TurnKit::Result.new(output_data: { "approved" => false, "violations" => [ { "rule" => "policy", "message" => "missing recommendation" } ] }, usage: TurnKit::Usage.new(input_tokens: 100, output_tokens: 20, cost: 0.02))
    )
    policy = TurnKit::OutputPolicy.new(content: "Require a recommendation.")
    workflow = TurnKit::Agent.new(orchestrator: true, name: "research", client: client, output_policy: policy, output_policy_mode: :report)

    run = workflow.run("Create a brief")

    assert run.completed?
    refute run.policy_clean?
    assert_equal 140, run.usage.total_tokens
    assert_in_delta 0.03, run.cost.total
    assert_equal 1, run.turn_records.length
  end
  def test_output_policy_revision_loop_can_repair_dirty_output
    policy = ->(output) { { rule: "recommendation", message: "missing recommendation" } unless output.include?("Recommendation") }
    client = FakeClient.new(TurnKit::Result.new(text: "Draft"), TurnKit::Result.new(text: "Recommendation: pilot"))
    agent = TurnKit::Agent.new(name: "writer", client: client, output_policy: policy, output_retries: 1)

    run = agent.run("Write memo")

    assert run.completed?
    assert run.policy_clean?
    assert_equal "Recommendation: pilot", run.output_text
    assert_equal 2, client.calls.length
    assert_includes run.messages.map(&:text).join("\n"), "previous output failed policy checks"
  end
end
