# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class SaveImplementationConcern < TurnKit::Tool
      description "Save an implementation risk, caveat, ambiguity, or engineering concern."
      usage_hint "Use when source material has a practical consequence for implementation."
      parameter :title, :string, required: true
      parameter :severity, :string, required: true, description: "One of: low, medium, high."
      parameter :category, :string, required: true, description: "One of: api_design, compatibility, performance, security, state, testing, other."
      parameter :explanation, :string, required: true
      parameter :recommendation, :string, required: true
      parameter :source_url, :string, required: true
      parameter :citation, :string, required: true

      def call(title:, severity:, category:, explanation:, recommendation:, source_url:, citation:, context:)
        concern = TechnicalExplainer.store.save_implementation_concern(
          title: title,
          severity: severity,
          category: category,
          explanation: explanation,
          recommendation: recommendation,
          source_url: source_url,
          citation: citation
        )
        { saved: true, implementation_concern: concern.to_h }
      end
    end
  end
end
