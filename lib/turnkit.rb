# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require "time"
require "date"
require "pathname"

require_relative "turnkit/version"
require_relative "turnkit/error"
require_relative "turnkit/id"
require_relative "turnkit/clock"
require_relative "turnkit/cost"
require_relative "turnkit/budget"
require_relative "turnkit/event"
require_relative "turnkit/model_request"
require_relative "turnkit/schema_check"
require_relative "turnkit/agent"
require_relative "turnkit/client"
require_relative "turnkit/conversation"
require_relative "turnkit/message"
require_relative "turnkit/record"
require_relative "turnkit/image_result"
require_relative "turnkit/media_input"
require_relative "turnkit/media_analysis_result"
require_relative "turnkit/result"
require_relative "turnkit/skill"
require_relative "turnkit/output_audit"
require_relative "turnkit/output_policy"
require_relative "turnkit/prompt_data"
require_relative "turnkit/prompt_context"
require_relative "turnkit/system_prompt"
require_relative "turnkit/store"
require_relative "turnkit/memory_store"
require_relative "turnkit/compaction"
require_relative "turnkit/tool"
require_relative "turnkit/image_tool"
require_relative "turnkit/view_media_tool"
require_relative "turnkit/tool_call"
require_relative "turnkit/tool_execution"
require_relative "turnkit/sub_agent_tool"
require_relative "turnkit/load_skill_tool"
require_relative "turnkit/message_projection"
require_relative "turnkit/tool_runner"
require_relative "turnkit/turn"
require_relative "turnkit/usage"
require_relative "turnkit/run"
require_relative "turnkit/adapters/codex"
require_relative "turnkit/adapters/ruby_llm"
require_relative "turnkit/active_record_store"

module TurnKit
  class << self
    attr_accessor :default_model, :client, :store, :logger
    attr_accessor :max_iterations, :timeout, :max_depth, :max_tool_executions
    attr_accessor :max_tool_executions_by_name
    attr_accessor :max_spend, :prompt_cache
    attr_accessor :compaction
    attr_accessor :output_policy_model, :output_policy_thinking
    attr_accessor :cost_rates, :cost_calculator
    attr_accessor :prompt_sections, :prompt_behavior, :available_skills
    attr_accessor :prompt_data_max_chars, :context_contributors
    attr_accessor :on_event
  end

  self.default_model = "claude-sonnet-4-5"
  self.store = MemoryStore.new
  self.client = Adapters::RubyLLM.new
  self.max_iterations = 25
  self.timeout = 300
  self.max_depth = 3
  self.max_tool_executions = 100
  self.max_tool_executions_by_name = {}
  self.max_spend = nil
  self.prompt_cache = :auto
  self.compaction = true
  self.cost_rates = {}
  self.prompt_sections = SystemPrompt::DEFAULT_SECTIONS.dup
  self.prompt_data_max_chars = 20_000
  self.available_skills = []
  self.context_contributors = []
  self.on_event = nil
  self.output_policy_model = nil
  self.output_policy_thinking = { effort: :low }

  def self.configure
    yield self
  end

  def self.reconcile_stale!(before: Clock.now - (timeout || 300))
    store.find_stale_turns(before: before).each do |turn|
      store.update_turn(turn.fetch("id"), "status" => "stale", "completed_at" => Clock.now)
    end
  end

  def self.check_output_policy(output, constraints: [], context: {})
    OutputAudit.check(output, constraints: constraints, context: context)
  end

  def self.paint(prompt, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: {}, client: nil)
    image_client = client || self.client
    image_client.paint(prompt: prompt, model: model, provider: provider, size: size, assume_model_exists: assume_model_exists, input_images: input_images, mask: mask, params: params, metadata: metadata).images.first
  end

  def self.view_media(media, objective:, model:, provider: nil, output_schema: nil, params: {}, metadata: {}, client: nil)
    media_client = client || self.client
    media_client.view_media(media: media, objective: objective, model: model, provider: provider, output_schema: output_schema, params: params, metadata: metadata).media_analyses.first
  end
end
