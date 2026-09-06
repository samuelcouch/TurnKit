# frozen_string_literal: true

require "ruby_llm"
require "turnkit"

module TurnKitExamples
  # New model IDs can postdate the catalog bundled with RubyLLM. Refresh only
  # when needed, using provider metadata endpoints, never an inference request.
  def self.prepare_model(model)
    RubyLLM.models.find(model)
  rescue RubyLLM::ModelNotFoundError
    TurnKit::Adapters::RubyLLM.new.validate!(model: model)
    RubyLLM.models.refresh!(remote_only: true)
    RubyLLM.models.find(model)
  end
end
