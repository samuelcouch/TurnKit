# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class SaveResearchBrief < TurnKit::Tool
      description "Save the final implementation-oriented research brief."
      usage_hint "Use once the brief is ready and source-backed, after saving the source document and any important concepts or implementation concerns."
      parameter :title, :string, required: true
      parameter :audience, :string, required: true
      parameter :summary, :string, required: true
      parameter :key_takeaways, :array, required: true
      parameter :implementation_notes, :array, required: true
      parameter :risks, :array, required: true
      parameter :open_questions, :array, required: false
      parameter :citations, :array, required: true

      def call(title:, audience:, summary:, key_takeaways:, implementation_notes:, risks:, citations:, open_questions: [], context:)
        brief = TechnicalExplainer.store.save_research_brief(
          title: title,
          audience: audience,
          summary: summary,
          key_takeaways: key_takeaways,
          implementation_notes: implementation_notes,
          risks: risks,
          open_questions: open_questions,
          citations: citations
        )
        { saved: true, research_brief: brief.to_h }
      end
    end
  end
end
