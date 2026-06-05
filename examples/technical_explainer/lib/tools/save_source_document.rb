# frozen_string_literal: true

module TechnicalExplainer
  module Tools
    class SaveSourceDocument < TurnKit::Tool
      description "Save an extracted source document in the local example store."
      usage_hint "Use after extracting a source that supports the final brief. Include the most relevant extracted excerpts when available so saved state preserves provenance."
      parameter :url, :string, required: true
      parameter :title, :string, required: true
      parameter :document_type, :string, required: true, description: "One of: paper, rfc, spec, api_docs, changelog, blog_post, other."
      parameter :primary_source, :boolean, required: true
      parameter :publisher, :string, required: false
      parameter :published_at, :string, required: false
      parameter :excerpts, :array, required: false
      parameter :full_content, :string, required: false

      def call(url:, title:, document_type:, primary_source:, publisher: nil, published_at: nil, excerpts: [], full_content: nil, context:)
        document = TechnicalExplainer.store.save_source_document(
          url: url,
          title: title,
          document_type: document_type,
          primary_source: primary_source,
          publisher: publisher,
          published_at: published_at,
          excerpts: excerpts,
          full_content: full_content
        )
        { saved: true, source_document: document.to_h }
      end
    end
  end
end
