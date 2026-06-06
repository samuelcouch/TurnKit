# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require "time"
require "date"

require_relative "turnkit/version"
require_relative "turnkit/error"
require_relative "turnkit/id"
require_relative "turnkit/clock"
require_relative "turnkit/cost"
require_relative "turnkit/budget"
require_relative "turnkit/agent"
require_relative "turnkit/client"
require_relative "turnkit/conversation"
require_relative "turnkit/message"
require_relative "turnkit/record"
require_relative "turnkit/result"
require_relative "turnkit/skill"
require_relative "turnkit/prompt_data"
require_relative "turnkit/prompt_context"
require_relative "turnkit/prompt_contribution"
require_relative "turnkit/system_prompt"
require_relative "turnkit/store"
require_relative "turnkit/memory_store"
require_relative "turnkit/tool"
require_relative "turnkit/tool_call"
require_relative "turnkit/tool_execution"
require_relative "turnkit/sub_agent_tool"
require_relative "turnkit/message_projection"
require_relative "turnkit/tool_runner"
require_relative "turnkit/turn"
require_relative "turnkit/usage"
require_relative "turnkit/adapters/ruby_llm"
require_relative "turnkit/stores/active_record_store"

require_relative "turnkit/rails/railtie" if defined?(Rails)

module TurnKit
  class << self
    attr_accessor :default_model, :client, :store, :logger
    attr_accessor :max_iterations, :timeout, :max_depth, :max_tool_executions
    attr_accessor :cost_limit, :prompt_cache
    attr_accessor :cost_rates, :cost_calculator
    attr_accessor :prompt_sections, :prompt_behavior, :available_skills
    attr_accessor :prompt_data_max_chars, :context_contributors
    attr_accessor :system_prompt_contributors, :model_prompt_contributors
    attr_accessor :conversation_record_class, :turn_record_class
    attr_accessor :message_record_class, :tool_execution_record_class
  end

  self.default_model = "claude-sonnet-4-5"
  self.store = MemoryStore.new
  self.client = Adapters::RubyLLM.new
  self.max_iterations = 25
  self.timeout = 300
  self.max_depth = 3
  self.max_tool_executions = 100
  self.prompt_cache = :auto
  self.cost_rates = {}
  self.prompt_sections = SystemPrompt::DEFAULT_SECTIONS.dup
  self.prompt_data_max_chars = 20_000
  self.available_skills = []
  self.context_contributors = []
  self.system_prompt_contributors = []
  self.model_prompt_contributors = {}

  def self.reconcile_stale!(before: Clock.now - (timeout || 300))
    store.find_stale_turns(before: before).each do |turn|
      store.update_turn(turn.fetch("id"), "status" => "stale", "completed_at" => Clock.now)
    end
  end
end
