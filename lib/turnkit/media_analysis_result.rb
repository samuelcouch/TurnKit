# frozen_string_literal: true

module TurnKit
  class MediaAnalysisResult
    attr_reader :text, :data, :model, :provider, :usage, :params, :media, :metadata, :error

    def self.from_h(value)
      new(**value.transform_keys(&:to_sym))
    end

    def initialize(text: "", data: nil, model: nil, provider: nil, usage: Usage.new, params: {}, media: {}, metadata: {}, error: nil, **)
      @text = text.to_s
      @data = data
      @model = model
      @provider = provider
      @usage = usage.is_a?(Usage) ? usage : Usage.from_h(usage || {})
      @params = params || {}
      @media = media || {}
      @metadata = metadata || {}
      @error = error
    end

    def data?
      !data.nil?
    end

    alias structured? data?

    def cost
      Cost.from_usage(usage, model: model)
    end

    def to_h
      {
        "text" => text,
        "data" => data,
        "model" => model,
        "provider" => provider,
        "usage" => usage.to_h,
        "cost" => cost.to_h,
        "params" => params,
        "media" => media,
        "metadata" => metadata,
        "error" => error
      }.compact
    end
  end
end
