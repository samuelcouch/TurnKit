# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class SaveConcept < TurnKit::Tool
      description "Save a key technical concept from the source material."
      usage_hint "Use for concepts that are important to the requested audience."
      parameter :name, :string, required: true
      parameter :short_explanation, :string, required: true
      parameter :detailed_explanation, :string, required: false
      parameter :why_it_matters, :string, required: true
      parameter :source_url, :string, required: true
      parameter :citation, :string, required: true

      def call(name:, short_explanation:, why_it_matters:, source_url:, citation:, detailed_explanation: nil, context:)
        concept = TechnicalExplainer.store.save_concept(
          name: name,
          short_explanation: short_explanation,
          detailed_explanation: detailed_explanation,
          why_it_matters: why_it_matters,
          source_url: source_url,
          citation: citation
        )
        { saved: true, concept: concept.to_h }
      end
    end
  end
end
