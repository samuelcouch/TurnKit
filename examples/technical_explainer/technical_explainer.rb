# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "turnkit"
require_relative "lib/models"
require_relative "lib/prompt_files"
require_relative "lib/store"
require_relative "lib/parallel_client"
require_relative "lib/tools/parallel_web_search"
require_relative "lib/tools/parallel_web_extract"
require_relative "lib/tools/save_source_document"
require_relative "lib/tools/save_concept"
require_relative "lib/tools/save_implementation_concern"
require_relative "lib/tools/save_research_brief"
require_relative "lib/tools/list_saved_briefs"

module TechnicalExplainer
  class << self
    attr_accessor :store, :parallel_client
  end
end

TechnicalExplainer.store = TechnicalExplainer::Store.new
TechnicalExplainer.parallel_client = TechnicalExplainer::ParallelClient.new

TurnKit.default_model = ENV["TURNKIT_MODEL"] || if !ENV.fetch("ANTHROPIC_API_KEY", "").empty?
  TurnKit.default_model
elsif !ENV.fetch("GOOGLE_API_KEY", "").empty?
  "gemini-2.5-flash"
elsif !ENV.fetch("OPENAI_API_KEY", "").empty?
  "gpt-4.1-mini"
else
  TurnKit.default_model
end

thinking = {}
thinking[:effort] = ENV["TURNKIT_THINKING_EFFORT"] unless ENV.fetch("TURNKIT_THINKING_EFFORT", "").empty?
thinking[:budget] = Integer(ENV["TURNKIT_THINKING_BUDGET"]) unless ENV.fetch("TURNKIT_THINKING_BUDGET", "").empty?
thinking = nil if thinking.empty?

TurnKit.context_contributors << ->(_context) {
  TechnicalExplainer::StoreContext.new(TechnicalExplainer.store).to_live_context
}

root = File.expand_path(__dir__)
prompt_files = TechnicalExplainer::PromptFiles.new(root)
skills = %w[
  technical_explainer
  source_finder
  implementation_review
].map do |name|
  TurnKit::Skill.from_file(File.join(root, "skills", "#{name}.md"))
end

request_text = ARGV.join(" ").strip
request_text = "Explain https://arxiv.org/abs/2606.03673 for a Ruby engineer building research-analysis tools. Focus on implementation risks." if request_text.empty?

request = TechnicalExplainer::ExplainerRequest.new(
  question: request_text,
  audience: ENV.fetch("AUDIENCE", "software builder"),
  requested_at: Time.now
)

agent = TurnKit::Agent.new(
  name: "SpecReader",
  description: "Turns technical source material into practical implementation briefs.",
  instructions: prompt_files.instructions,
  system_prompt: ->(prompt) { prompt_files.system_prompt(prompt) },
  thinking: thinking,
  skills: skills,
  tools: [
    TechnicalExplainer::Tools::ParallelWebSearch,
    TechnicalExplainer::Tools::ParallelWebExtract,
    TechnicalExplainer::Tools::SaveSourceDocument,
    TechnicalExplainer::Tools::SaveConcept,
    TechnicalExplainer::Tools::SaveImplementationConcern,
    TechnicalExplainer::Tools::SaveResearchBrief,
    TechnicalExplainer::Tools::ListSavedBriefs
  ]
)

conversation = agent.conversation(subject: request)
turn = conversation.ask(request_text)

if turn.failed?
  warn "Turn failed: #{conversation.store.load_turn(turn.id).fetch("error").inspect}"
end

puts turn.output_text
puts
puts "--- Saved example state ---"
puts TechnicalExplainer.store.summary
