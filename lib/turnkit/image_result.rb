# frozen_string_literal: true

require "base64"
require "open-uri"

module TurnKit
  class ImageResult
    attr_reader :url, :data, :mime_type, :revised_prompt, :model, :provider, :usage, :params, :metadata

    def self.from_h(value)
      new(**value.transform_keys(&:to_sym))
    end

    def initialize(url: nil, data: nil, mime_type: nil, revised_prompt: nil, model: nil, provider: nil, usage: Usage.new, params: {}, metadata: {}, **)
      @url = url
      @data = data
      @mime_type = mime_type
      @revised_prompt = revised_prompt
      @model = model
      @provider = provider
      @usage = usage.is_a?(Usage) ? usage : Usage.from_h(usage || {})
      @params = params || {}
      @metadata = metadata || {}
    end

    def to_blob
      raise Error, "image has no url or data" if url.to_s.empty? && data.to_s.empty?

      data ? Base64.decode64(data) : URI.open(url, &:read)
    end

    def cost
      Cost.from_usage(usage, model: model)
    end

    def to_h
      {
        "url" => url,
        "data" => data,
        "mime_type" => mime_type,
        "revised_prompt" => revised_prompt,
        "model" => model,
        "provider" => provider,
        "usage" => usage.to_h,
        "cost" => cost.to_h,
        "params" => params,
        "metadata" => metadata
      }.compact
    end
  end
end
