# frozen_string_literal: true

require "timeout"

module DurableResearch
  SOURCE = "local:durable-report-requirements"

  class ReadResearch < TurnKit::Tool
    tool_name "read_research"
    description "Read the fixed product brief and its citation identifier."
    def call(context:)
      { source: SOURCE, text: File.read(File.join(__dir__, "source.md")) }
    end
  end

  class SaveReport < TurnKit::Tool
    tool_name "save_report"
    description "Validate and save the final report after both reviewers finish."
    parameter :body, :string, required: true
    parameter :sources, :array, required: true, items: :string
    terminal! { |result| result.fetch("body") }

    def call(body:, sources:, context:)
      children = context.turn.store.list_turns(root_turn_id: context.turn.root_turn_id)
        .select { |row| row["parent_turn_id"] == context.turn.id }
      unless children.map { |row| row["agent_name"] }.sort == %w[evidence_review risk_review] && children.all? { |row| row["status"] == "completed" }
        raise TurnKit::ToolError, "Both reviewers must complete before publication"
      end
      raise TurnKit::ToolError, "Report must cite the research dossier" unless sources == [SOURCE] && body.include?(SOURCE)
      report = Report.create!(turn_uid: context.turn.id, body: body, sources: sources)
      { "report_id" => report.id, "body" => body, "sources" => sources }
    end
  end

  # Database barriers make concurrency and crash tests deterministic across
  # actual worker processes. They exist only in fake mode, not the live workflow.
  def self.gate(turn_id, name)
    signal = Signal.create!(turn_uid: turn_id, name: name, pid: Process.pid)
    Timeout.timeout(60) { sleep 0.05 until signal.reload.released? }
  end

  class FixtureClient < TurnKit::Client
    def initialize(role)
      @role = role
    end

    def chat(model:, messages:, metadata:, **)
      id = metadata.fetch(:turn_id)
      record = TurnKit.store.load_turn(id)
      root = TurnKit.store.load_turn(record.fetch("root_turn_id"))
      options = TurnKit.store.load_conversation(root.fetch("conversation_id")).fetch("metadata")
      case @role
      when "coordinator"
        executions = TurnKit.store.list_tool_executions(turn_id: id)
        names = executions.map { |row| row["tool_name"] }
        if !names.include?("read_research")
          calls = [TurnKit::ToolCall.new(id: "research", name: "read_research", arguments: {})]
        elsif !names.include?("evidence_review")
          task = "Review this dossier: #{File.read(File.join(__dir__, 'source.md'))}"
          calls = %w[evidence_review risk_review].map { |name| TurnKit::ToolCall.new(id: name, name: name, arguments: { task: task }) }
        else
          reviews = executions.select { |row| %w[evidence_review risk_review].include?(row["tool_name"]) }
            .map { |row| row.fetch("result").fetch("result") }
          calls = [TurnKit::ToolCall.new(id: "publish", name: "save_report", arguments: {
            body: "Use durable submission and recoverable report publication.\n#{reviews.join("\n")}\nSource: #{SOURCE}", sources: [SOURCE]
          })]
        end
        TurnKit::Result.new(tool_calls: calls, model: model)
      when "evidence_review", "risk_review"
        DurableResearch.gate(id, "review_started") if options["gate_reviews"]
        TurnKit::Result.new(text: "#{@role}: checked the dossier; preserve delivery and publication invariants. #{SOURCE}", model: model)
      when "inbox"
        user_text = messages.select { |message| message[:role].to_s == "user" }.map { |message| message[:content].to_s }
        DurableResearch.gate(id, "busy") if user_text.last == "hold"
        TurnKit::Result.new(text: "Acknowledged: #{user_text.join(' | ')}", model: model)
      end
    end

    def paint(model:, **)
      image = TurnKit::ImageResult.new(data: Base64.strict_encode64("fixture-image-bytes"), mime_type: "image/png", model: model)
      TurnKit::Result.new(parts: [image.to_h.merge("type" => "image")], model: model)
    end

    def view_media(model:, **)
      analysis = TurnKit::MediaAnalysisResult.new(text: "Fixture image reviewed", model: model)
      TurnKit::Result.new(parts: [analysis.to_h.merge("type" => "media_analysis")], model: model)
    end
  end

  class PrepareImage < TurnKit::Tool
    tool_name "prepare_image"
    description "Generate and inspect an image, returning its durable message reference."
    terminal! { |result| result.to_json }
    def call(context:)
      turn = context.turn
      image = turn.paint("A simple diagram-like illustration of two reviewers checking a report, no text.",
        model: "gpt-image-2", provider: :openai, size: "1024x1024")
      analysis = turn.view_media(TurnKit::MediaInput.bytes(image.to_blob, mime_type: image.mime_type, filename: "report.png"),
        objective: "Describe the image and assess its relevance to reviewing a report.", model: "gemini-3.8-flash", provider: :gemini)
      message = turn.conversation.messages.find(&:image?)
      { "conversation_id" => turn.conversation.id, "image_message_id" => message.id, "review" => analysis.text }
    end
  end

  class MediaFixtureClient < FixtureClient
    def chat(model:, **)
      TurnKit::Result.new(tool_calls: [TurnKit::ToolCall.new(id: "image", name: "prepare_image", arguments: {})], model: model)
    end
  end

  def self.register_agents
    TurnKit.store = TurnKit::ActiveRecordStore.new
    TurnKit.compaction = false
    # Stale-worker threshold, separate from the agents' total task deadline.
    TurnKit.timeout = 10
    TurnKit.on_event = lambda do |event|
      next if LIVE || event.type != "tool_call.completed" || event.payload[:name] != "save_report"
      turn = TurnKit.load_turn(event.turn_id)
      next unless turn.conversation.metadata["crash_after_publish"]
      Signal.create!(turn_uid: turn.id, name: "crashed_after_publish", pid: Process.pid)
      Process.kill("KILL", Process.pid)
    end
    model = LIVE ? ENV.fetch("TURNKIT_MODEL", "gpt-5.6-sol") : "fixture"
    if LIVE
      require_relative "../shared/model_registry"
      # Scenario subprocesses reserve stdout for JSON; registry refresh logs
      # must use the application's stderr logger as well.
      RubyLLM.configure { |config| config.logger = Rails.logger }
      TurnKitExamples.prepare_model(model)
      TurnKitExamples.prepare_model("gemini-3.8-flash") if ENV["TURNKIT_DEMO_MEDIA"] == "1"
    end
    client = ->(role) { LIVE ? TurnKit::Adapters::RubyLLM.new : FixtureClient.new(role) }
    # Sol's Chat Completions endpoint supports function tools only without reasoning.
    thinking = { effort: "none" } if LIVE && model == "gpt-5.6-sol"
    reviewers = %w[evidence_review risk_review].map do |name|
      TurnKit::Agent.new(name: name, model: model, client: client.call(name), tools: [], timeout: 180,
        instructions: "You are #{name}. Read only the supplied dossier. Return a concise evidence-backed review; do not take actions.")
    end
    TurnKit.register(TurnKit::Agent.new(name: "coordinator", model: model, client: client.call("coordinator"),
      sub_agents: reviewers, tools: [ReadResearch, SaveReport], thinking: thinking, timeout: 180, max_iterations: 20,
      max_tool_executions: 12, max_spend: LIVE ? 2.0 : nil,
      instructions: "Read the research dossier. Dispatch evidence_review and risk_review together in one response with complete dossier context. After both succeed, synthesize their findings and call save_report exactly once with body and sources. Cite local:durable-report-requirements in the body. Never invent sources."))
    TurnKit.register(TurnKit::Agent.new(name: "inbox", model: model, client: client.call("inbox"), timeout: 180,
      instructions: "Acknowledge the latest message, incorporating relevant conversation history. Do not invoke other agents."))
    TurnKit.register(TurnKit::Agent.new(name: "media", model: model,
      client: LIVE ? TurnKit::Adapters::RubyLLM.new : MediaFixtureClient.new("media"), tools: [PrepareImage], thinking: thinking, timeout: 180, max_spend: LIVE ? 2.0 : nil,
      instructions: "Call prepare_image once to generate and review an illustration. Its result ends the task."))
  end
end
DurableResearch.register_agents
