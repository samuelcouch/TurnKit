# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/shunt/shunt"
require "tmpdir"

class ShuntTest < Minitest::Test
  MARKER = "UNIQUE_MARKER_TOKEN_9f3a"

  def setup
    super
    @root = Dir.mktmpdir
    write("big.rb", Array.new(400) { |i| "line #{i} #{MARKER}" })
    write("ref_test.rb", [ "class RefTest < Minitest::Test", "  def test_ref = assert true", "end" ])
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(path, lines)
    File.write(File.join(@root, path), lines.join("\n") + "\n")
  end

  def call_tool(id, name, arguments)
    TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: id, name: name, arguments: arguments) ])
  end

  def agent(client)
    Shunt.agent(root: @root, model: "primary", worker_model: "worker", client: client)
  end

  def tool_results(run)
    run.turn.conversation.messages.select { |message| message.kind == "tool_result" }.map { |message| message.content.first }
  end

  def test_bulk_read_keeps_file_bytes_out_of_the_parent_context
    client = FakeClient.new(
      call_tool("c1", "bulk_read", { question: "What does big.rb do?", paths: [ "big.rb" ] }),
      TurnKit::Result.new(text: "- big.rb: 400 numbered lines"),
      TurnKit::Result.new(text: "It lists 400 lines.")
    )
    savings = Shunt::Savings.new
    run = agent(client).run("Explain big.rb", async: true)
    run.run! { |event| savings.call(event) }

    assert run.completed?, run.error.inspect
    parent_calls, worker_calls = client.calls.partition { |call| call[:model] == "primary" }
    assert_equal 2, parent_calls.length
    assert_equal 1, worker_calls.length
    parent_calls.each { |call| refute_includes JSON.generate(call.values_at(:messages, :instructions)), MARKER }
    worker_text = JSON.generate(worker_calls.first[:messages])
    assert_includes worker_text, MARKER
    assert_includes worker_text, "What does big.rb do?"
    assert_includes worker_text, "<file path=\\\"big.rb\\\">"

    report = savings.to_h
    assert_equal 1, report["delegations"]
    assert_operator report["delegated_tokens"], :>, File.size(File.join(@root, "big.rb")) / 4
    assert_operator report["returned_tokens"], :<, 100
    assert_match(/\A9\d%\z/, report["saved"])
  end

  def test_read_gate_blocks_only_full_reads_of_large_files
    write("at.rb", Array.new(350) { "x" })
    write("over.rb", Array.new(351) { "x" })
    gate = Shunt.read_gate(@root)
    read = Shunt::ReadFile.new(root: @root)
    cases = {
      { "path" => "at.rb" } => :allow,
      { "path" => "over.rb" } => :block,
      { "path" => "over.rb", "offset" => 10 } => :allow,
      { "path" => "over.rb", "limit" => 40 } => :allow,
      { "path" => "missing.rb" } => :allow
    }
    cases.each do |arguments, expected|
      decision, reason = gate.call(tool: read, arguments: arguments, context: nil)
      assert_equal expected, decision, arguments.inspect
      assert_includes reason, "bulk_read" if expected == :block
    end
    assert_equal :allow, gate.call(tool: Shunt::BulkRead.new(agent: nil, root: @root), arguments: { "paths" => [ "over.rb" ] }, context: nil)
  end

  def test_blocked_read_returns_a_redirect_the_model_can_follow
    client = FakeClient.new(
      call_tool("c1", "read_file", { path: "big.rb" }),
      call_tool("c2", "read_file", { path: "big.rb", offset: 1, limit: 2 }),
      TurnKit::Result.new(text: "done")
    )
    run = agent(client).run("Read big.rb")

    blocked, allowed = tool_results(run)
    assert blocked.fetch("error")
    error = JSON.parse(blocked.fetch("text"))
    assert_includes error.fetch("message"), "big.rb is 400 lines"
    assert_includes error.fetch("message"), "bulk_read"
    assert error.dig("details", "tool_policy_blocked")
    refute_includes JSON.generate(client.calls[1][:messages]), MARKER
    refute allowed.fetch("error")
    assert_equal "line 0 #{MARKER}\nline 1 #{MARKER}\n", JSON.parse(allowed.fetch("text")).fetch("content")
    assert_equal %w[failed completed], run.tool_executions.map(&:status)
  end

  def test_code_write_sends_the_reference_to_the_worker_and_returns_only_the_path
    client = FakeClient.new(
      call_tool("c1", "code_write", { spec: "Test Foo#bar", reference: "ref_test.rb", target: "foo_test.rb" }),
      call_tool("w1", "write_file", { path: "foo_test.rb", content: "class FooTest < Minitest::Test\nend\n" }),
      TurnKit::Result.new(text: "done")
    )
    run = agent(client).run("Write tests for Foo")

    assert run.completed?, run.error.inspect
    assert_equal "class FooTest < Minitest::Test\nend\n", File.read(File.join(@root, "foo_test.rb"))
    worker_text = JSON.generate(client.calls[1][:messages])
    assert_includes worker_text, "class RefTest < Minitest::Test"
    assert_includes worker_text, "Write foo_test.rb"
    result = JSON.parse(tool_results(run).first.fetch("text"))
    assert_equal "Wrote foo_test.rb (35 bytes).", result.fetch("result")
    refute_includes JSON.generate(client.calls.last[:messages]), "FooTest"
  end

  def test_code_write_requires_a_reference_and_confines_paths
    client = FakeClient.new(
      call_tool("c1", "code_write", { spec: "Test Foo", target: "foo_test.rb" }),
      call_tool("c2", "bulk_read", { question: "?", paths: [ "../etc/passwd" ] }),
      TurnKit::Result.new(text: "done")
    )
    run = agent(client).run("Write tests")

    messages = tool_results(run).map { |result| JSON.parse(result.fetch("text")).fetch("message") }
    assert_equal "missing required argument: reference", messages[0]
    assert_equal "../etc/passwd is outside the project root", messages[1]
    assert_equal %w[primary primary primary], client.calls.map { |call| call[:model] }
  end
end
