# frozen_string_literal: true

require_relative "test_helper"

class ScopedContextTest < Minitest::Test
  def test_concurrent_agents_get_only_their_own_context_and_snapshot_defaults
    TurnKit.context_contributors = [->(_) { { name: "boot", content: "boot-value" } }]
    agents = %w[alice bob].map do |name|
      client = FakeClient.new(TurnKit::Result.new(text: "done"))
      [TurnKit::Agent.new(name: name, client: client, context_contributors: [->(_) { { name: "private", content: "#{name}-private" } }]), client]
    end
    TurnKit.context_contributors << ->(_) { { name: "late", content: "must-not-leak" } }
    data = { "nested" => { "value" => "original" } }
    pending = agents.first.first.run("work", context: data, async: true)
    data["nested"]["value"] = "changed"
    workers = [Thread.new { pending.run! }, Thread.new { agents.last.first.run("work", context: { "owner" => "bob" }) }]
    workers.each(&:value)
    agents.each do |agent, client|
      prompt = client.calls.first.fetch(:instructions)
      assert_includes prompt, "#{agent.name}-private"
      refute_includes prompt, "#{agent.name == 'alice' ? 'bob' : 'alice'}-private"
      refute_includes prompt, "must-not-leak"
      assert_includes prompt, "boot-value"
    end
    assert_equal "original", pending.turn.context.dig("nested", "value")
    pending.turn.context["nested"]["value"] = "mutated copy"
    assert_equal "original", pending.turn.context.dig("nested", "value")
  end

  def test_skill_tools_are_unavailable_until_successful_load_and_do_not_leak_to_another_run
    tool = Class.new(TurnKit::Tool) do
      tool_name "skill_read"
      def call(context:) = { "result" => "read" }
    end
    skill = TurnKit::Skill.new(key: "research", name: "Research", content: "Read carefully", tools: [tool])
    result = ->(id, name, args) { TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: id, name: name, arguments: args)]) }
    client = FakeClient.new(result.call("denied", "skill_read", {}), result.call("load", "load_skill", { key: "research" }),
      result.call("allowed", "skill_read", {}), TurnKit::Result.new(text: "done"), TurnKit::Result.new(text: "another"))
    agent = TurnKit::Agent.new(name: "skills", client: client, available_skills: [skill])
    run = agent.run("read")
    assert run.completed?
    assert run.tool_executions.first.failed?
    assert run.tool_executions.last.completed?
    refute_includes client.calls.first[:tools].map(&:tool_name), "skill_read"
    assert_includes client.calls[2][:tools].map(&:tool_name), "skill_read"
    agent.run("new independent run")
    refute_includes client.calls.last[:tools].map(&:tool_name), "skill_read"
  end
end
