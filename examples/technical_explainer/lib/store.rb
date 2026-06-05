# frozen_string_literal: true

require "json"

module TechnicalExplainer
  class Store
    attr_reader :source_documents, :concepts, :implementation_concerns, :research_briefs

    def initialize
      @source_documents = []
      @concepts = []
      @implementation_concerns = []
      @research_briefs = []
    end

    def save_source_document(attributes)
      document = SourceDocument.new({
        id: next_id("src", source_documents),
        extracted_at: Time.now,
        excerpts: []
      }.merge(symbolize(attributes)))
      source_documents << document
      document
    end

    def save_concept(attributes)
      concept = Concept.new({ id: next_id("concept", concepts) }.merge(symbolize(attributes)))
      concepts << concept
      concept
    end

    def save_implementation_concern(attributes)
      concern = ImplementationConcern.new({ id: next_id("risk", implementation_concerns) }.merge(symbolize(attributes)))
      implementation_concerns << concern
      concern
    end

    def save_research_brief(attributes)
      brief = ResearchBrief.new({
        id: next_id("brief", research_briefs),
        created_at: Time.now,
        key_takeaways: [],
        implementation_notes: [],
        risks: [],
        open_questions: [],
        citations: []
      }.merge(symbolize(attributes)))
      research_briefs << brief
      brief
    end

    def summary
      {
        source_documents: source_documents.map { |document| document.to_h.slice(:id, :title, :url, :document_type, :primary_source) },
        concepts: concepts.map { |concept| concept.to_h.slice(:id, :name, :source_url) },
        implementation_concerns: implementation_concerns.map { |concern| concern.to_h.slice(:id, :title, :severity, :category) },
        research_briefs: research_briefs.map { |brief| brief.to_h.slice(:id, :title, :audience) }
      }.to_json
    end

    private
      def next_id(prefix, collection)
        "#{prefix}_#{collection.length + 1}"
      end

      def symbolize(hash)
        hash.transform_keys(&:to_sym)
      end
  end

  class StoreContext
    def initialize(store)
      @store = store
    end

    def to_live_context
      TurnKit::LiveContextContribution.new(
        name: "technical_explainer_store",
        trusted: true,
        content: {
          saved_source_documents: @store.source_documents.length,
          saved_concepts: @store.concepts.length,
          saved_implementation_concerns: @store.implementation_concerns.length,
          saved_research_briefs: @store.research_briefs.length
        }.to_json
      )
    end
  end
end
