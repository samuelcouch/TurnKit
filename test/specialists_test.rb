# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/turnkit/specialists"

class SpecialistsTest < Minitest::Test
  def test_oracle_has_confined_read_capability_and_rejects_unmarked_tools
    Dir.mktmpdir do |root|
      File.write(File.join(root, "facts.txt"), "verified")
      agent = TurnKit::Specialists.oracle(model: "advisor-model", root: root, instructions: "Be concise.")
      tool = agent.tools.first

      assert_instance_of TurnKit::Agent, agent
      assert_equal "advisor-model", agent.model
      assert_equal "verified", tool.call(path: "facts.txt", context: nil).fetch("content")
      assert tool.read_only?
      assert_includes agent.instructions, "Be concise."
      assert_raises(TurnKit::ToolError) { tool.call(path: "../outside", context: nil) }
    end

    assert_raises(ArgumentError) { TurnKit::Specialists.oracle(model: "m", tools: [ SaveReport ]) }
  end

  def test_librarian_scopes_requests_and_decodes_file_content
    requests = []
    transport = lambda do |uri:, headers:|
      requests << [ uri, headers ]
      [ 200, JSON.generate({ "encoding" => "base64", "content" => Base64.strict_encode64("hello"),
        "html_url" => "https://github.com/acme/widgets/blob/main/README.md" }) ]
    end
    agent = TurnKit::Specialists.librarian(repository: "acme/widgets", model: "research-model", github_client: transport, token: "secret")
    result = agent.tools.first.call(operation: "file", path: "README.md", ref: "main", context: nil)

    assert_equal "hello", result.dig("data", "content")
    assert_equal "https://github.com/acme/widgets/blob/main/README.md", result["source"]
    assert_equal "api.github.com", requests.first.first.host
    assert_equal "/repos/acme/widgets/contents/README.md", requests.first.first.path
    assert_equal "Bearer secret", requests.first.last["Authorization"]
    assert_includes agent.instructions, "source URLs"
    assert_raises(ArgumentError) { TurnKit::Specialists.librarian(repository: "https://evil.test/x", model: "m") }
    agent.tools.first.call(operation: "file", path: "docs/usage guide+.md", context: nil)
    assert_equal "/repos/acme/widgets/contents/docs/usage%20guide%2B.md", requests.last.first.path
  end

  def test_painter_requires_application_gate_and_forwards_edit_inputs
    turn = Object.new
    calls = []
    turn.define_singleton_method(:paint) { |prompt, **arguments| calls << arguments.merge(prompt: prompt); TurnKit::ImageResult.new(url: "https://example.test/art.png") }
    message = Struct.new(:id) { def image? = true }.new("image-id")
    conversation = Struct.new(:id, :messages).new("conversation-id", [message])
    turn.define_singleton_method(:conversation) { conversation }
    context = Struct.new(:turn).new(turn)
    authorized = []
    gate = ->(request, context:) { authorized << request; true }
    agent = TurnKit::Specialists.painter(model: "chat-model", image_model: "image-model", authorization: gate, provider: :custom,
      params: { quality: "high" }, max_reference_images: 2)

    result = agent.tools.first.call(prompt: "paint it", reference_images: %w[a.png b.png], mask: "mask.png", context: context)

    assert_equal "https://example.test/art.png", result.dig("image", "url")
    assert_equal "image-id", result["image_message_id"]
    assert_equal %w[a.png b.png], calls.first[:input_images]
    assert_equal "mask.png", calls.first[:mask]
    assert_equal({ quality: "high" }, calls.first[:params])
    assert_equal "image-model", authorized.first[:model]

    denied = TurnKit::Specialists.painter(model: "m", image_model: "image", authorization: ->(_, context:) { false }).tools.first
    assert_raises(TurnKit::ToolError) { denied.call(prompt: "no", context: context) }
    assert_raises(ArgumentError) { TurnKit::Specialists.painter(model: "m", image_model: "image", authorization: true) }
    assert_raises(TurnKit::ToolValidationError) { agent.tools.first.call(prompt: "too many", reference_images: %w[a b c], context: context) }
    assert_equal 1, calls.length
  end

  def test_painter_runs_through_real_turn_and_returns_persisted_artifact
    image = TurnKit::ImageResult.new(data: Base64.strict_encode64("image bytes"), mime_type: "image/png", model: "image-model")
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: "paint", name: "paint_image", arguments: { prompt: "a pear" })]),
      TurnKit::Result.new(parts: [image.to_h.merge("type" => "image")], model: "image-model")
    )
    agent = TurnKit::Specialists.painter(model: "chat-model", image_model: "image-model", client: client,
      authorization: ->(_, context:) { context.principal == "authorized" })
    run = agent.run("Paint a pear", principal: "authorized")
    assert run.completed?, run.error.inspect
    assert run.tool_executions.first.completed?, run.tool_executions.first.error.inspect
    reference = JSON.parse(run.output_text)
    message = run.messages.find { |entry| entry.id == reference.fetch("image_message_id") }
    assert message.image?
    assert_equal "image bytes", TurnKit::ImageResult.from_h(message.content.find { |part| part["type"] == "image" }).to_blob
    refute reference.fetch("image").key?("data")
    assert_equal "a pear", client.calls.last[:prompt]
  end

  def test_read_only_specialists_reject_mutating_extensions_and_ignore_globals
    write = Class.new(TurnKit::Tool) { tool_name "write" }
    skill = TurnKit::Skill.new(key: "write", name: "Write", content: "Write files", tools: [write])
    TurnKit.available_skills = [skill]
    oracle = TurnKit::Specialists.oracle(model: "m")
    assert_empty oracle.available_skills
    assert_raises(ArgumentError) { TurnKit::Specialists.librarian(repository: "ruby/ruby", model: "m", tools: [write]) }
    assert_raises(ArgumentError) { TurnKit::Specialists.oracle(model: "m", available_skills: [skill]) }
  end
end
