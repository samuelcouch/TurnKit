# frozen_string_literal: true

require_relative "test_helper"

class MediaTest < Minitest::Test
  def test_image_result_decodes_blob_and_round_trips_through_result
    image = TurnKit::ImageResult.new(data: Base64.strict_encode64("png-bytes"), mime_type: "image/png", model: "image-model", provider: "gemini")
    result = TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], usage: TurnKit::Usage.new(cost: 0.01), model: "image-model")

    assert result.image?
    assert_equal "png-bytes", result.images.first.to_blob
    assert_equal "image/png", result.images.first.mime_type
    assert_equal "gemini", result.images.first.provider
  end
  def test_media_input_normalizes_paths_urls_io_and_bytes
    file = Tempfile.new([ "header", ".png" ])
    file.write("png-bytes")
    file.close

    path = TurnKit::MediaInput.new(file.path)
    url = TurnKit::MediaInput.new("https://example.com/demo.pdf")
    io = TurnKit::MediaInput.new(StringIO.new("audio"), filename: "clip.mp3")
    bytes = TurnKit::MediaInput.bytes("video", mime_type: "video/mp4", filename: "clip.mp4")

    assert_equal "path", path.source_type
    assert_equal "image", path.kind
    assert_equal "image/png", path.mime_type
    assert_equal "url", url.source_type
    assert_equal "pdf", url.kind
    assert_equal "audio", io.kind
    assert_equal "video", bytes.kind
    assert_instance_of StringIO, bytes.attachment_source
  ensure
    file&.unlink
  end
  def test_media_analysis_result_round_trips_through_result
    analysis = TurnKit::MediaAnalysisResult.new(text: "Looks good", data: { "approved" => true }, model: "media-model", provider: "gemini", usage: TurnKit::Usage.new(input_tokens: 3, cost: 0.01), media: { "kind" => "image" })
    result = TurnKit::Result.new(parts: [ analysis.to_h.merge("type" => "media_analysis") ], usage: analysis.usage, model: "media-model")

    assert result.media_analysis?
    assert_equal "Looks good", result.media_analyses.first.text
    assert_equal({ "approved" => true }, result.media_analyses.first.data)
    assert_equal "image", result.media_analyses.first.media.fetch("kind")
    assert_equal 0.01, result.usage.cost
  end
  def test_ruby_llm_adapter_paint_wraps_ruby_llm_and_normalizes_image
    verbose = nil
    original = nil
    require "ruby_llm"

    original = RubyLLM.method(:paint)
    calls = []
    fake_image = Struct.new(:url, :data, :mime_type, :revised_prompt, :model_id, :usage, :cost, keyword_init: true).new(
      data: Base64.strict_encode64("image"),
      mime_type: "image/png",
      revised_prompt: "revised",
      model_id: "resolved-image-model",
      usage: { "input_tokens" => 4 },
      cost: Struct.new(:total).new(0.02)
    )
    verbose = $VERBOSE
    $VERBOSE = nil
    RubyLLM.define_singleton_method(:paint) do |prompt, **kwargs|
      calls << kwargs.merge(prompt: prompt)
      fake_image
    end
    $VERBOSE = verbose

    result = TurnKit::Adapters::RubyLLM.new.paint(
      prompt: "paint it",
      model: "image-model",
      provider: :gemini,
      size: "1024x576",
      assume_model_exists: true,
      input_images: [ "reference.png" ],
      mask: "mask.png",
      metadata: { article_id: 1 }
    )

    assert_equal "paint it", calls.first.fetch(:prompt)
    assert_equal "image-model", calls.first.fetch(:model)
    assert_equal :gemini, calls.first.fetch(:provider)
    assert_equal "1024x576", calls.first.fetch(:size)
    assert_equal [ "reference.png" ], calls.first.fetch(:with)
    assert_equal "mask.png", calls.first.fetch(:mask)
    assert result.image?
    assert_equal "image", result.images.first.to_blob
    assert_equal "resolved-image-model", result.images.first.model
    assert_equal 4, result.usage.input_tokens
    assert_equal 0.02, result.usage.cost
  ensure
    if defined?(RubyLLM) && original
      $VERBOSE = nil
      RubyLLM.define_singleton_method(:paint, original)
    end
    $VERBOSE = verbose unless verbose.nil?
  end
  def test_ruby_llm_adapter_view_media_wraps_ruby_llm_content_and_normalizes_analysis
    verbose = nil
    original = nil
    require "ruby_llm"

    fake_chat = Class.new do
      attr_reader :messages, :schema, :params

      def initialize
        @messages = []
      end

      def with_schema(schema)
        @schema = schema
      end

      def with_params(**params)
        @params = params
      end

      def add_message(attributes)
        @messages << attributes
      end
    end.new
    fake_response = Struct.new(:content, :model_id, :input_tokens, :output_tokens, :cost, keyword_init: true).new(
      content: { "approved" => true },
      model_id: "resolved-media-model",
      input_tokens: 5,
      output_tokens: 2,
      cost: Struct.new(:total).new(0.03)
    )
    adapter = TurnKit::Adapters::RubyLLM.new
    adapter.define_singleton_method(:complete_without_tool_execution) { |chat| fake_response }
    original = RubyLLM.method(:chat)
    models = []
    verbose = $VERBOSE
    $VERBOSE = nil
    RubyLLM.define_singleton_method(:chat) do |model:|
      models << model
      fake_chat
    end
    $VERBOSE = verbose

    result = adapter.view_media(
      media: TurnKit::MediaInput.bytes("png", mime_type: "image/png", filename: "header.png"),
      objective: "Review it",
      model: "media-model",
      provider: :gemini,
      output_schema: { type: "object", properties: { approved: { type: "boolean" } } },
      params: { temperature: 0 },
      metadata: { article_id: 1 }
    )

    content = fake_chat.messages.first.fetch(:content)
    assert_equal [ "media-model" ], models
    assert_instance_of RubyLLM::Content, content
    assert_equal "Review it", content.text
    assert_equal "header.png", content.attachments.first.filename
    assert_equal "object", fake_chat.schema.fetch("type")
    assert_equal({ temperature: 0 }, fake_chat.params)
    assert result.media_analysis?
    assert_equal "resolved-media-model", result.media_analyses.first.model
    assert_equal({ "approved" => true }, result.media_analyses.first.data)
    assert_equal "image/png", result.media_analyses.first.media.fetch("mime_type")
    assert_equal 5, result.usage.input_tokens
    assert_equal 0.03, result.usage.cost
  ensure
    if defined?(RubyLLM) && original
      $VERBOSE = nil
      RubyLLM.define_singleton_method(:chat, original)
    end
    $VERBOSE = verbose unless verbose.nil?
  end
  def test_image_tool_generates_image_inside_workflow_and_satisfies_image_policy
    image = TurnKit::ImageResult.new(url: "https://example.com/header.png", mime_type: "image/png", model: "image-model", provider: "gemini")
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "image_1", name: "header_image", arguments: { title: "Launch" }) ]),
      TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], model: "image-model")
    )
    agent = TurnKit::Agent.new(name: "publisher", client: client, tools: [ HeaderImageTool ], output_policy: TurnKit::OutputPolicy.require_image)

    run = agent.run("Generate header")

    assert run.completed?
    assert run.policy_clean?
    assert_equal "https://example.com/header.png", run.output_text
    assert_equal "Create a header image for Launch", client.calls.last.fetch(:prompt)
    assert_equal "1024x576", client.calls.last.fetch(:size)
    assert_equal :gemini, client.calls.last.fetch(:provider)
    assert run.messages.any?(&:image?)
  end
  def test_image_tool_forwards_references_and_mask_and_retains_generated_bytes
    tool = Class.new(TurnKit::ImageTool) do
      tool_name "edit_image"
      model "image-model"
      parameter :reference, :string, required: true
      parameter :mask_path, :string, required: true

      def prompt(**)
        "Edit the reference"
      end

      def input_images(reference:, **)
        [ reference ]
      end

      def mask(mask_path:, **)
        mask_path
      end
    end
    image = TurnKit::ImageResult.new(data: Base64.strict_encode64("edited-png"), mime_type: "image/png")
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "edit", name: "edit_image", arguments: { reference: "reference.png", mask_path: "mask.png" }) ]),
      TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ]),
      TurnKit::Result.new(text: "Edited")
    )

    run = TurnKit::Agent.new(name: "artist", client: client, tools: [ tool ]).run("Edit this image")

    assert run.completed?
    assert_equal [ "reference.png" ], client.calls[1].fetch(:input_images)
    assert_equal "mask.png", client.calls[1].fetch(:mask)
    result = run.turn.tool_executions.first.result
    assert_equal "edited-png", TurnKit::ImageResult.from_h(result).to_blob
    assert run.messages.any?(&:image?)
  end

  def test_turn_paint_rejects_image_without_url_or_data
    image = TurnKit::ImageResult.new(model: "image-model")
    client = FakeClient.new(TurnKit::Result.new(parts: [ image.to_h.merge("type" => "image") ], model: "image-model"))
    agent = TurnKit::Agent.new(name: "artist", client: client)
    turn = agent.run("Generate later", async: true).turn

    error = assert_raises(TurnKit::Error) { turn.paint("paint", model: "image-model") }

    assert_equal "image client returned image without url or data", error.message
    assert turn.reload.failed?
  end
  def test_turn_paint_fails_claimed_turn_when_event_callback_raises
    agent = TurnKit::Agent.new(name: "artist", client: FakeClient.new, on_event: ->(event) { raise "listener boom" if event.type == "turn.started" })
    turn = agent.run("Generate later", async: true).turn

    error = assert_raises(RuntimeError) { turn.paint("paint", model: "image-model") }

    assert_equal "listener boom", error.message
    assert turn.reload.failed?
  end
  def test_turn_view_media_fails_claimed_turn_when_event_callback_raises
    agent = TurnKit::Agent.new(name: "reviewer", client: FakeClient.new, on_event: ->(event) { raise "listener boom" if event.type == "turn.started" })
    turn = agent.run("Review later", async: true).turn

    error = assert_raises(RuntimeError) do
      turn.view_media(TurnKit::MediaInput.bytes("png", mime_type: "image/png", filename: "header.png"), objective: "Review", model: "media-model")
    end

    assert_equal "listener boom", error.message
    assert turn.reload.failed?
  end
  def test_turn_paint_fails_claimed_turn_when_post_claim_setup_raises
    agent = TurnKit::Agent.new(name: "artist", client: FakeClient.new)
    turn = agent.run("Generate later", async: true).turn
    original_resume = TurnKit::Budget.method(:resume)
    verbose = $VERBOSE
    $VERBOSE = nil
    TurnKit::Budget.define_singleton_method(:resume) { |**| raise "budget boom" }
    $VERBOSE = verbose

    error = assert_raises(RuntimeError) { turn.paint("paint", model: "image-model") }

    assert_equal "budget boom", error.message
    assert turn.reload.failed?
  ensure
    if original_resume
      $VERBOSE = nil
      TurnKit::Budget.define_singleton_method(:resume, original_resume)
    end
    $VERBOSE = verbose unless verbose.nil?
  end

  def test_turn_paint_rejects_completed_turns
    agent = TurnKit::Agent.new(name: "artist", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    turn = agent.run("Finish").turn

    error = assert_raises(TurnKit::Error) { turn.paint("paint", model: "image-model") }

    assert_equal "cannot paint for completed turn", error.message
  end
  def test_view_media_tool_analyzes_media_inside_workflow_and_satisfies_policy
    file = Tempfile.new([ "header", ".png" ])
    file.write("png")
    file.close
    media = TurnKit::MediaInput.new(file.path)
    analysis = TurnKit::MediaAnalysisResult.new(text: "approved", model: "media-model", provider: "gemini", media: media.to_h)
    client = FakeClient.new(
      TurnKit::Result.new(tool_calls: [ TurnKit::ToolCall.new(id: "media_1", name: "header_review", arguments: { path: file.path }) ]),
      TurnKit::Result.new(parts: [ analysis.to_h.merge("type" => "media_analysis") ], model: "media-model")
    )
    agent = TurnKit::Agent.new(name: "publisher", client: client, tools: [ HeaderReviewTool ], output_policy: TurnKit::OutputPolicy.require_media_analysis)

    run = agent.run("Review header")

    assert run.completed?
    assert run.policy_clean?
    assert_equal "approved", run.output_text
    assert_equal "Review #{File.basename(file.path)}", client.calls.last.fetch(:objective)
    assert_equal :gemini, client.calls.last.fetch(:provider)
    assert run.messages.any?(&:media_analysis?)
  ensure
    file&.unlink
  end
  def test_turn_view_media_emits_media_failed
    client = Class.new(FakeClient) do
      def view_media(**)
        raise TurnKit::Error, "adapter failed"
      end
    end.new
    events = []
    agent = TurnKit::Agent.new(name: "reviewer", client: client, on_event: ->(event) { events << event })
    turn = agent.run("Review later", async: true).turn

    error = assert_raises(TurnKit::Error) do
      turn.view_media(TurnKit::MediaInput.bytes("png", mime_type: "image/png", filename: "header.png"), objective: "Review", model: "media-model")
    end

    assert_equal "adapter failed", error.message
    assert turn.reload.failed?
    assert_includes events.map(&:type), "media.failed"
  end
  def test_media_analysis_messages_project_without_binary_data
    agent = TurnKit::Agent.new(name: "worker", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    conversation = agent.conversation
    message = conversation.append_message(
      role: "assistant",
      kind: "media_analysis",
      content: [ { "type" => "media_analysis", "text" => "approved", "media" => { "kind" => "image", "mime_type" => "image/png", "filename" => "header.png", "metadata" => { "secret" => "nope" } }, "model" => "media-model", "provider" => "gemini" } ]
    )

    projected = TurnKit::MessageProjection.for([ message ]).first

    assert_equal :assistant, projected.fetch(:role)
    assert_includes projected.fetch(:content), "Media analysis"
    assert_includes projected.fetch(:content), "approved"
    refute_includes projected.fetch(:content), "secret"
  end
  def test_image_messages_project_without_binary_data
    agent = TurnKit::Agent.new(name: "worker", client: FakeClient.new(TurnKit::Result.new(text: "done")))
    conversation = agent.conversation
    message = conversation.append_message(
      role: "assistant",
      kind: "image",
      content: [ { "type" => "image", "data" => Base64.strict_encode64("bytes"), "url" => "https://example.com/image.png", "mime_type" => "image/png", "model" => "image-model", "provider" => "gemini" } ]
    )

    projected = TurnKit::MessageProjection.for([ message ]).first

    assert_equal :assistant, projected.fetch(:role)
    assert_includes projected.fetch(:content), "Generated image"
    assert_includes projected.fetch(:content), "https://example.com/image.png"
    refute_includes projected.fetch(:content), Base64.strict_encode64("bytes")
  end
end
