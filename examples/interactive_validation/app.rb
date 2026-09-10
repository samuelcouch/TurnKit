# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "sidekiq"
require "turnkit"
require "turnkit/job"
require "ruby_llm"
RubyLLM.config.logger = Logger.new($stderr, level: Logger::WARN)

module InteractiveValidation
  class Application < Rails::Application
    config.root = __dir__
    config.load_defaults 8.1
    config.eager_load = false
    config.active_job.queue_adapter = :sidekiq
    config.logger = ActiveSupport::Logger.new($stderr)
    config.log_level = :error
    config.secret_key_base = "local-headless-validation-only"
  end
end
Rails.application.initialize!
database = ENV.fetch("TURNKIT_VALIDATION_DATABASE_URL", "postgresql:///turnkit_interactive_validation")
abort "Only the isolated turnkit_interactive_validation database is supported" unless database == "postgresql:///turnkit_interactive_validation"
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "turnkit_interactive_validation", pool: 16)

Sidekiq.configure_server { |config| config.redis = { url: "redis://127.0.0.1:6380/0" } }
Sidekiq.configure_client { |config| config.redis = { url: "redis://127.0.0.1:6380/0" }; config.logger.level = Logger::ERROR }
TurnKit::Job.queue_as :interactive_validation

module InteractiveValidation
  %w[Conversation Turn Message ToolExecution Delivery Wait].each do |name|
    klass = Class.new(ActiveRecord::Base)
    const_set(name, klass)
    klass.table_name = "iv_#{name.underscore.pluralize}"
  end
  class Barrier < ActiveRecord::Base
    self.table_name = "iv_barriers"
  end
  class Evidence < ActiveRecord::Base
    self.table_name = "iv_evidence"
  end
  PROVIDER = ENV.fetch("TURNKIT_VALIDATION_PROVIDER", "openai")
  MODEL = { "openai" => "gpt-6-astra", "anthropic" => "claude-opus-4-8", "gemini" => "gemini-3.1-pro-preview" }.fetch(PROVIDER)
  EFFORT = PROVIDER == "openai" ? "xhigh" : "high"
  CAMPAIGN = PROVIDER == "openai" ? "ruby_llm_2" : "#{PROVIDER}_#{RubyLLM::VERSION}"

  def self.wait_at(turn_id, name)
    barrier = Barrier.find_by(turn_uid: turn_id, name: name)
    return unless barrier
    barrier.update!(entered: true, pid: Process.pid)
    Timeout.timeout(120) { sleep 0.05 until barrier.reload.released }
    if barrier.crash && !barrier.crashed
      barrier.update!(crashed: true)
      Process.exit!(86) # A real worker process dies, without a Ruby continuation.
    end
  end

  # Instrument the client boundary only; the parent implementation still sends
  # every request to the selected provider. No synthetic responses or executor.
  class ObservedClient < TurnKit::Adapters::RubyLLM
    def initialize
      super(protocol: PROVIDER == "openai" ? :responses : nil)
    end

    def chat(**options)
      previous = Thread.current[:iv_request]
      Thread.current[:iv_request] = options.fetch(:metadata)
      super
    ensure
      Thread.current[:iv_request] = previous
    end

    def complete_without_tool_execution(chat)
      raise "Live calls require TURNKIT_INTERACTIVE_LIVE=1" unless ENV["TURNKIT_INTERACTIVE_LIVE"] == "1"
      cap = PROVIDER == "openai" ? 30 : 12
      raise "Validation call cap reached" if Evidence.where(kind: "provider").where("data ->> 'adapter' = ?", CAMPAIGN).count >= cap
      if chat.respond_to?(:with_max_output_tokens)
        chat.with_max_output_tokens(1200)
        payload = JSON.parse(JSON.generate(chat.render))
      else
        chat.with_params(**(PROVIDER == "gemini" ? { generationConfig: { maxOutputTokens: 1200 } } : { max_tokens: 1200 }))
        rendered = chat.instance_variable_get(:@provider).send(:render_payload, chat.messages, tools: chat.tools,
          temperature: nil, model: chat.model, thinking: chat.instance_variable_get(:@thinking))
        payload = JSON.parse(JSON.generate(RubyLLM::Utils.deep_merge(rendered, chat.params)))
      end
      effort = payload.dig("reasoning", "effort") || payload.dig("output_config", "effort") || payload.dig("generationConfig", "thinkingConfig", "thinkingLevel")
      raise "Exact model/effort required" unless chat.model.id == MODEL && effort == EFFORT
      replay = chat.messages.filter_map do |message|
        next unless message.role == :assistant
        if message.respond_to?(:raw_content)
          message.raw_content
        elsif message.content.is_a?(RubyLLM::Content::Raw)
          message.content.value
        end
      end
      response = super
      body = response.raw.body
      sent = response.raw.env.request_body
      sent = JSON.parse(sent) if sent.is_a?(String)
      sent_effort = sent.dig("reasoning", "effort") || sent.dig("output_config", "effort") || sent.dig("generationConfig", "thinkingConfig", "thinkingLevel")
      raise "Actual request effort mismatch" unless sent_effort == EFFORT
      if PROVIDER != "openai"
        sent_messages = sent["messages"] || sent["contents"]
        sent_replay = sent_messages.select { |message| %w[assistant model].include?(message["role"]) }.map { |message| message["content"] || message["parts"] }
        raise "Opaque replay changed" unless sent_replay == replay
      end
      metadata = Thread.current.fetch(:iv_request)
      turn_id = metadata.fetch(:turn_id)
      number = Evidence.where(kind: "provider", turn_uid: turn_id).count + 1
      returned_model = body["model"] || body["modelVersion"]
      raise "Provider model mismatch" unless returned_model == MODEL || (PROVIDER != "openai" && returned_model.to_s.start_with?("#{MODEL}-"))
      raise "Provider effort mismatch" if PROVIDER == "openai" && body.dig("reasoning", "effort") != EFFORT
      input = payload["input"] || []
      blocks = body["output"] || body["content"] || body.dig("candidates", 0, "content", "parts")
      Evidence.create!(kind: "provider", turn_uid: turn_id, data: {
        adapter: CAMPAIGN, provider: PROVIDER, http_status: response.raw.status,
        request_id: metadata[:request_id], response_id: body["id"] || body["responseId"],
        model: returned_model, effort: effort, status: body["status"] || body["stop_reason"] || body.dig("candidates", 0, "finishReason"),
        usage: body["usage"] || body["usageMetadata"], worker_pid: Process.pid,
        estimated_cost_usd: response.cost&.total,
        actual_request_effort: sent_effort, replayed_assistant_messages: replay.length, opaque_replay_exact: PROVIDER != "openai" ? true : nil,
        thinking_config: payload["reasoning"] || payload.slice("thinking", "output_config").presence || payload.dig("generationConfig", "thinkingConfig"),
        opaque_blocks: blocks.count { |item| item["signature"] || item["thoughtSignature"] || item["encrypted_content"] || item["type"] == "redacted_thinking" },
        input: input.map { |item| item.slice("type", "role", "call_id", "name", "output").merge(
          item["role"] == "user" ? { "content" => item["content"] } : {}) },
        output: blocks.map { |item| item.slice("type", "role", "call_id", "name").merge(
          item["functionCall"] ? { "type" => "function_call", "name" => item.dig("functionCall", "name") } :
            item["type"] == "tool_use" ? { "type" => "function_call", "call_id" => item["id"] } : {}) }
      })
      # Child barriers are installed before the runtime receives its response.
      if TurnKit.store.load_turn(turn_id)["agent_name"] == "validation_child" && number == 1
        Barrier.find_or_create_by!(turn_uid: turn_id, name: "response_1")
      end
      InteractiveValidation.wait_at(turn_id, "response_#{number}")
      response
    rescue RubyLLM::Error => error
      rejected = error.response if error.respond_to?(:response)
      status = rejected.status if rejected.respond_to?(:status)
      Evidence.create!(kind: "provider_failure", turn_uid: Thread.current[:iv_request].fetch(:turn_id),
        data: { adapter: CAMPAIGN, provider: PROVIDER, model: MODEL, effort: EFFORT, http_status: status, error_class: error.class.name })
      raise TurnKit::ModelError, "#{PROVIDER} request failed: #{error.class} HTTP #{status}"
    end
  end

  class ReadEvidence < TurnKit::Tool
    tool_name "read_evidence"
    description "Read the local research fixture, without changing external state."
    parameter :section, :string, required: true

    def call(section:, context:)
      Evidence.create!(kind: "tool", turn_uid: context.turn.id, data: {
        section: section, principal: context.principal, worker_pid: Process.pid
      })
      InteractiveValidation.wait_at(context.turn.id, "tool_#{section}")
      { section: section, finding: File.read(File.join(__dir__, "evidence.txt")) }
    end
  end

  STORE = TurnKit::ActiveRecordStore.new(**%w[conversation turn message tool_execution delivery wait].to_h do |name|
    ["#{name}_class".to_sym, "InteractiveValidation::#{name.camelize}"]
  end)
  TurnKit.store = STORE
  RubyLLM.config.max_retries = 0
  RubyLLM.config.request_timeout = 180
  TurnKit.client = ObservedClient.new
  TurnKit.timeout = 600
  TurnKit.compaction = false
  TurnKit.cost_rates = { "gpt-6-astra" => { input: 10, output: 50, cache_read: 1, cache_write: 12.5, thinking: 50 } }
  TurnKit.authorization_policy = ->(action, principal:, **) { principal != "denied" }

  def self.agent(name, **options)
    TurnKit.register(TurnKit::Agent.new(name: name, model: MODEL, thinking: { effort: EFFORT },
      system_prompt: "Follow the latest user instruction exactly. Use only the requested tools. Keep answers brief. Never invent tool findings.",
      max_iterations: 6, max_tool_executions: 6, max_spend: 2, timeout: 600, compaction: false, **options))
  end
  agent("validation_reader", tools: [ReadEvidence])
  agent("validation_plain")
  child = agent("validation_child")
  agent("validation_parent", sub_agents: [child])
  agent("validation_launcher", sub_agents: [child], tools: [TurnKit::LaunchAgentTool])
end

TurnKit::Job.after_perform do |job|
  InteractiveValidation::Evidence.create!(kind: "job", turn_uid: job.arguments.first || "maintenance",
    data: { worker_pid: Process.pid, job_id: job.job_id })
end
