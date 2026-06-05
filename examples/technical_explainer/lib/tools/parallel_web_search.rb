# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class ParallelWebSearch < TurnKit::Tool
      description "Search the web with Parallel Search and return source excerpts."
      usage_hint "Use when the user names a document/spec without a URL, asks for latest/current information, or when source authority must be verified before extraction. Do not use for URL-first requests unless the extracted source is insufficient."
      parameter :objective, :string, required: true, description: "Natural-language research objective."
      parameter :search_queries, :array, required: true, description: "Two or three targeted keyword queries."
      parameter :session_id, :string, required: false, description: "Parallel session_id from a previous search or extract call."

      def call(objective:, search_queries:, session_id: nil, context:)
        TechnicalExplainer.parallel_client.search(
          objective: objective,
          search_queries: search_queries,
          session_id: session_id
        )
      end
    end
  end
end
