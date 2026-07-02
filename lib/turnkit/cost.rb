# frozen_string_literal: true

module TurnKit
  class Cost
    COMPONENTS = %i[input output cache_read cache_write thinking].freeze
    PER_MILLION = 1_000_000.0

    attr_reader :input, :output, :cache_read, :cache_write, :thinking

    def self.aggregate(costs)
      costs = costs.compact
      return new unless costs.any?

      if costs.any? { |cost| COMPONENTS.any? { |component| !cost.public_send(component).nil? } }
        values = COMPONENTS.to_h do |component|
          amounts = costs.filter_map { |cost| cost.public_send(component) }
          [ component, amounts.any? ? amounts.sum : nil ]
        end
        return new(**values)
      end

      totals = costs.map(&:total)
      return new(total: totals.sum) if totals.none?(&:nil?)

      new
    end

    def self.from_usage(usage, model: nil)
      return new(total: usage.cost) if usage.cost

      custom = custom_cost(usage, model)
      return custom if custom

      rates = TurnKit.cost_rates[model.to_s] || TurnKit.cost_rates[model&.to_sym]
      rates ? from_rates(usage, rates) : from_ruby_llm(usage, model)
    end

    def self.from_records(records)
      aggregate(records.map { |record| from_record(record) })
    end

    def self.from_record(record)
      attrs = record.transform_keys(&:to_s)
      usage = attrs["usage"] || {}
      return from_hash(usage["cost_details"] || usage[:cost_details]) if usage["cost_details"] || usage[:cost_details]
      return new(total: attrs["cost"]) if attrs["cost"]

      from_usage(Usage.from_h(usage), model: attrs["model"])
    end

    RATE_KEYS = %i[input output cache_read cache_write thinking].freeze

    # Rates are USD per million tokens, keyed by component.
    def self.from_rates(usage, rates)
      rates = rates.transform_keys(&:to_sym)
      unknown = rates.keys - RATE_KEYS
      raise ConfigError, "unknown cost rate keys: #{unknown.join(", ")} (use: #{RATE_KEYS.join(", ")})" if unknown.any?

      new(
        input: amount(usage.input_tokens, rates[:input]),
        output: amount(usage.output_tokens, rates[:output]),
        cache_read: amount(usage.cached_tokens, rates[:cache_read]),
        cache_write: amount(usage.cache_write_tokens, rates[:cache_write]),
        thinking: amount(usage.thinking_tokens, rates[:thinking]),
        strict: true
      )
    end

    # Estimates cost from RubyLLM's model pricing registry (ruby_llm >= 1.16).
    # Returns an empty Cost when ruby_llm is not loaded or the model is not in
    # the registry; any other failure raises.
    def self.from_ruby_llm(usage, model)
      return new unless defined?(::RubyLLM) && model

      model_info = ::RubyLLM.models.find(model)
      tokens = ::RubyLLM::Tokens.new(
        input: usage.input_tokens,
        output: usage.output_tokens,
        cached: usage.cached_tokens,
        cache_creation: usage.cache_write_tokens,
        thinking: usage.thinking_tokens
      )
      from_hash(::RubyLLM::Cost.new(tokens: tokens, model: model_info).to_h)
    rescue ::RubyLLM::ModelNotFoundError
      new
    end

    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_sym)
      new(
        input: hash[:input],
        output: hash[:output],
        cache_read: hash[:cache_read],
        cache_write: hash[:cache_write],
        thinking: hash[:thinking],
        total: hash[:total]
      )
    end

    def self.custom_cost(usage, model)
      return unless TurnKit.cost_calculator

      value = TurnKit.cost_calculator.call(usage, model)
      case value
      when nil
        nil
      when Cost
        value
      when Hash
        from_hash(value)
      else
        new(total: value)
      end
    end

    def self.amount(tokens, price)
      return nil if tokens.to_i.positive? && price.nil?
      return 0.0 if tokens.to_i.zero?

      tokens.to_i * price.to_f / PER_MILLION
    end

    def initialize(input: nil, output: nil, cache_read: nil, cache_write: nil, thinking: nil, total: nil, strict: false)
      @input = number(input)
      @output = number(output)
      @cache_read = number(cache_read)
      @cache_write = number(cache_write)
      @thinking = number(thinking)
      @total = number(total)
      @strict = strict
    end

    def total
      return @total if @total
      return nil if @strict && COMPONENTS.any? { |component| public_send(component).nil? }

      values = COMPONENTS.filter_map { |component| public_send(component) }
      values.empty? ? nil : values.sum
    end

    def to_h
      {
        "input" => input,
        "output" => output,
        "cache_read" => cache_read,
        "cache_write" => cache_write,
        "thinking" => thinking,
        "total" => total
      }.compact
    end

    private
      def number(value)
        value.nil? ? nil : value.to_f
      end
  end
end
