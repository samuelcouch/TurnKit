# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class ListSavedBriefs < TurnKit::Tool
      description "List briefs and source documents saved during this example run."
      usage_hint "Use when the user asks what has been saved or when follow-up work should reuse saved context."

      def call(context:)
        {
          source_documents: TechnicalExplainer.store.source_documents.map(&:to_h),
          concepts: TechnicalExplainer.store.concepts.map(&:to_h),
          implementation_concerns: TechnicalExplainer.store.implementation_concerns.map(&:to_h),
          research_briefs: TechnicalExplainer.store.research_briefs.map(&:to_h)
        }
      end
    end
  end
end
