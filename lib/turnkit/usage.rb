# frozen_string_literal: true

module TurnKit
  class Usage
    attr_reader :input_tokens, :output_tokens, :cached_tokens, :cache_write_tokens, :cost

    def self.aggregate(usages)
      usages = usages.compact
      costs = usages.map(&:cost).compact
      cost = costs.sum if costs.any?
      new(
        input_tokens: usages.sum(&:input_tokens),
        output_tokens: usages.sum(&:output_tokens),
        cached_tokens: usages.sum(&:cached_tokens),
        cache_write_tokens: usages.sum(&:cache_write_tokens),
        cost: cost
      )
    end

    def self.from_records(records)
      aggregate(records.map { |record| from_h(record.fetch("usage", {})) })
    end

    def self.from_h(hash)
      attrs = hash.transform_keys(&:to_s)
      cost = attrs["cost"] unless attrs["cost"].is_a?(Hash)
      new(
        input_tokens: attrs["input_tokens"],
        output_tokens: attrs["output_tokens"],
        cached_tokens: attrs["cached_tokens"],
        cache_write_tokens: attrs["cache_write_tokens"],
        cost: cost
      )
    end

    def initialize(input_tokens: 0, output_tokens: 0, cached_tokens: 0, cache_write_tokens: 0, cost: nil)
      @input_tokens = input_tokens.to_i
      @output_tokens = output_tokens.to_i
      @cached_tokens = cached_tokens.to_i
      @cache_write_tokens = cache_write_tokens.to_i
      @cost = cost
    end

    def total_tokens
      input_tokens + output_tokens + cached_tokens + cache_write_tokens
    end

    def to_h
      {
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "cached_tokens" => cached_tokens,
        "cache_write_tokens" => cache_write_tokens,
        "total_tokens" => total_tokens,
        "cost" => cost
      }.compact
    end
  end
end
