# frozen_string_literal: true

require "json"
require "time"

module TechnicalExplainer
  ExplainerRequest = Struct.new(:question, :audience, :requested_at, keyword_init: true) do
    def to_prompt
      {
        question: question,
        audience: audience,
        requested_at: requested_at.iso8601
      }.to_json
    end
  end

  SourceDocument = Struct.new(
    :id,
    :url,
    :title,
    :document_type,
    :publisher,
    :published_at,
    :primary_source,
    :excerpts,
    :full_content,
    :extracted_at,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        url: url,
        title: title,
        document_type: document_type,
        publisher: publisher,
        published_at: published_at,
        primary_source: primary_source,
        excerpts: excerpts,
        full_content: full_content,
        extracted_at: extracted_at&.iso8601
      }
    end
  end

  Concept = Struct.new(
    :id,
    :name,
    :short_explanation,
    :detailed_explanation,
    :why_it_matters,
    :source_url,
    :citation,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        name: name,
        short_explanation: short_explanation,
        detailed_explanation: detailed_explanation,
        why_it_matters: why_it_matters,
        source_url: source_url,
        citation: citation
      }
    end
  end

  ImplementationConcern = Struct.new(
    :id,
    :title,
    :severity,
    :category,
    :explanation,
    :recommendation,
    :source_url,
    :citation,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        title: title,
        severity: severity,
        category: category,
        explanation: explanation,
        recommendation: recommendation,
        source_url: source_url,
        citation: citation
      }
    end
  end

  ResearchBrief = Struct.new(
    :id,
    :title,
    :audience,
    :summary,
    :key_takeaways,
    :implementation_notes,
    :risks,
    :open_questions,
    :citations,
    :created_at,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        title: title,
        audience: audience,
        summary: summary,
        key_takeaways: key_takeaways,
        implementation_notes: implementation_notes,
        risks: risks,
        open_questions: open_questions,
        citations: citations,
        created_at: created_at&.iso8601
      }
    end
  end
end
