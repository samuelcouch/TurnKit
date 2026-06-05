# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class ParallelWebExtract < TurnKit::Tool
      description "Read known URLs with Parallel Extract and return LLM-ready markdown or excerpts."
      usage_hint "Use before answering any request that includes a URL, and after search finds canonical source URLs. This is the source-grounding tool for papers, RFCs, specs, docs, changelogs, PDFs, and arXiv pages."
      parameter :urls, :array, required: true, description: "One or more public URLs to extract."
      parameter :objective, :string, required: true, description: "What content to target from the page."
      parameter :search_queries, :array, required: false, description: "Optional keyword queries to focus extracted excerpts."
      parameter :session_id, :string, required: false, description: "Parallel session_id from a previous search or extract call."

      def call(urls:, objective:, search_queries: nil, session_id: nil, context:)
        TechnicalExplainer.parallel_client.extract(
          urls: urls,
          objective: objective,
          search_queries: search_queries,
          session_id: session_id
        )
      end
    end
  end
end
