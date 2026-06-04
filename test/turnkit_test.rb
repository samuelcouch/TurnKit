# frozen_string_literal: true

require_relative "test_helper"

class SaveReport < TurnKit::Tool
  description "Save a report."
  parameter :title, :string, required: true
  parameter :body, :string, required: true

  def self.ends_turn? = true
  def self.completion_message(result) = "Saved #{result.fetch("report_id")}."

  def call(title:, body:, context:)
    { report_id: "rep_1", title: title, body: body }
  end
end

class ErrorPayloadTool < TurnKit::Tool
  tool_name "error_payload"

  def call(context:)
    { error: "ordinary data", ok: true }
  end
end

class RaisingTool < TurnKit::Tool
  tool_name "raising_tool"

  def call(context:)
    raise "boom"
  end
end

class ContextCheckingTool < TurnKit::Tool
  tool_name "context_checking_tool"

  def call(context:)
    raise "missing context" unless context.is_a?(TurnKit::ToolContext)

    { ok: true }
  end
end

class TurnKitTest < Minitest::Test
  def test_agent_runs_plain_text_turn
    client = FakeClient.new(TurnKit::Result.new(text: "hello", usage: TurnKit::Usage.new(input_tokens: 2, output_tokens: 3)))
    agent = TurnKit::Agent.new(name: "helper", model: "model-a", instructions: "Be brief.", client: client)

    turn = agent.conversation.ask("Hi")

    assert turn.completed?
    assert_equal "hello", turn.output_text
    assert_equal "model-a", client.calls.first.fetch(:model)
    assert_equal [ :user ], client.calls.first.fetch(:messages).map { |message| message.fetch(:role) }
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

  def test_skills_are_added_to_instructions
    skill = TurnKit::Skill.new(key: "research", name: "Research", content: "Use sources.")
    client = FakeClient.new(TurnKit::Result.new(text: "ok"))
    agent = TurnKit::Agent.new(name: "researcher", instructions: "Base", skills: [ skill ], client: client)

    agent.conversation.ask("Go")

    assert_includes client.calls.first.fetch(:instructions), "Base"
    assert_includes client.calls.first.fetch(:instructions), "## Skill: Research"
    assert_includes client.calls.first.fetch(:instructions), "Use sources."
  end

  def test_concurrent_turns_use_start_snapshot
    client = FakeClient.new(TurnKit::Result.new(text: "A"), TurnKit::Result.new(text: "B"))
    conversation = TurnKit::Agent.new(name: "helper", client: client).conversation

    conversation.say("first")
    turn_a = conversation.ask("a", async: true)
    conversation.say("between")
    turn_b = conversation.ask("b", async: true)

    turn_a.run!
    turn_b.run!

    first_call_messages = client.calls.first.fetch(:messages).map { |message| message.fetch(:content) }
    second_call_messages = client.calls.last.fetch(:messages).map { |message| message.fetch(:content) }

    assert_includes first_call_messages, "first"
    assert_includes first_call_messages, "a"
    refute_includes first_call_messages, "between"
    refute_includes first_call_messages, "b"

    assert_includes second_call_messages, "between"
    assert_includes second_call_messages, "b"
    refute_includes second_call_messages, "A"
  end

  def test_sub_agent_creates_nested_turn
    child_client = FakeClient.new(TurnKit::Result.new(text: "child answer"))
    parent_client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_child", name: "writer", arguments: { task: "draft" }) ]),
      TurnKit::Result.new(text: "parent done")
    )
    writer = TurnKit::Agent.new(name: "writer", client: child_client)
    parent = TurnKit::Agent.new(name: "parent", client: parent_client, sub_agents: [ writer ])

    turn = parent.conversation.ask("delegate")

    assert turn.completed?
    assert_equal "parent done", turn.output_text
    child_turn = TurnKit.store.list_turns(root_turn_id: turn.id).find { |row| row.fetch("id") != turn.id }
    refute_nil child_turn
    assert_equal turn.id, child_turn.fetch("parent_turn_id")
  end

  def test_reconcile_stale_marks_old_running_turns_stale
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)
    TurnKit.store.update_turn(turn.id, "status" => "running", "heartbeat_at" => Time.utc(2000, 1, 1))

    TurnKit.reconcile_stale!(before: Time.utc(2000, 1, 2))

    assert_equal "stale", TurnKit.store.load_turn(turn.id).fetch("status")
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

  def test_store_rejects_unknown_update_attributes
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)

    error = assert_raises(ArgumentError) do
      TurnKit.store.update_turn(turn.id, "bogus" => true)
    end
    assert_includes error.message, "unknown turn update attributes"
  end

  def test_store_rejects_unknown_statuses
    agent = TurnKit::Agent.new(name: "helper", client: FakeClient.new)
    turn = agent.conversation.ask("later", async: true)

    error = assert_raises(ArgumentError) do
      TurnKit.store.update_turn(turn.id, "status" => "lost")
    end
    assert_includes error.message, "unknown turn status"
  end

  def test_content_only_messages_extract_text
    conversation = TurnKit::Agent.new(name: "helper", client: FakeClient.new).conversation

    message = conversation.append_message(
      role: "user",
      kind: "text",
      content: [ { "type" => "text", "text" => "from content" } ]
    )

    assert_equal "from content", message.text
  end

  def test_tool_execution_gets_turnkit_context
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "call_context", name: "context_checking_tool") ]),
      TurnKit::Result.new(text: "done")
    )
    agent = TurnKit::Agent.new(name: "helper", client: client, tools: [ ContextCheckingTool ])

    turn = agent.conversation.ask("run")

    assert turn.completed?
    assert turn.tool_executions.first.completed?
  end

  def test_ruby_llm_adapter_does_not_execute_turnkit_tools
    tool_class = TurnKit::Adapters::RubyLLM.new.send(:ruby_llm_tool, ContextCheckingTool)

    error = assert_raises(TurnKit::ToolError) do
      tool_class.new.execute
    end
    assert_includes error.message, "tools must be executed by TurnKit turns"
  end

  def test_ruby_llm_adapter_configures_provider_keys_from_environment
    require "ruby_llm"

    original_openai_key = RubyLLM.config.openai_api_key
    original_gemini_key = RubyLLM.config.gemini_api_key
    original_env_openai_key = ENV["OPENAI_API_KEY"]
    original_env_gemini_key = ENV["GEMINI_API_KEY"]
    RubyLLM.config.openai_api_key = nil
    RubyLLM.config.gemini_api_key = nil
    ENV["OPENAI_API_KEY"] = "openai-test-key"
    ENV["GEMINI_API_KEY"] = "gemini-test-key"

    TurnKit::Adapters::RubyLLM.new.send(:configure_from_environment)

    assert_equal "openai-test-key", RubyLLM.config.openai_api_key
    assert_equal "gemini-test-key", RubyLLM.config.gemini_api_key
  ensure
    RubyLLM.config.openai_api_key = original_openai_key if defined?(RubyLLM)
    RubyLLM.config.gemini_api_key = original_gemini_key if defined?(RubyLLM)
    ENV["OPENAI_API_KEY"] = original_env_openai_key
    ENV["GEMINI_API_KEY"] = original_env_gemini_key
  end

  def test_ruby_llm_adapter_preserves_tool_messages
    require "ruby_llm"

    adapter = TurnKit::Adapters::RubyLLM.new
    chat = Class.new do
      attr_reader :messages

      def initialize
        @messages = []
      end

      def add_message(attributes)
        @messages << RubyLLM::Message.new(attributes)
      end
    end.new

    adapter.send(:add_message, chat, {
      role: :assistant,
      content: "",
      tool_calls: [ { "id" => "call_1", "name" => "context_checking_tool", "arguments" => { "ok" => true } } ]
    })
    adapter.send(:add_message, chat, { role: :tool, content: "{\"ok\":true}", tool_call_id: "call_1" })

    assistant_message = chat.messages.first
    tool_message = chat.messages.last
    assert assistant_message.tool_call?
    assert_equal "context_checking_tool", assistant_message.tool_calls.fetch("call_1").name
    assert tool_message.tool_result?
    assert_equal "call_1", tool_message.tool_call_id
  end
end
