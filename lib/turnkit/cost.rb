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

    def self.from_rates(usage, rates)
      rates = rates.transform_keys(&:to_sym)
      new(
        input: amount(usage.input_tokens, rates[:input] || rates[:input_per_million]),
        output: amount(usage.output_tokens, rates[:output] || rates[:output_per_million]),
        cache_read: amount(usage.cached_tokens, rates[:cache_read] || rates[:cached_input] || rates[:cache_read_input_per_million] || rates[:cached_input_per_million]),
        cache_write: amount(usage.cache_write_tokens, rates[:cache_write] || rates[:cache_creation] || rates[:cache_write_input_per_million] || rates[:cache_creation_input_per_million]),
        thinking: amount(usage.thinking_tokens, rates[:thinking] || rates[:reasoning] || rates[:thinking_output] || rates[:reasoning_output] || rates[:thinking_output_per_million] || rates[:reasoning_output_per_million]),
        strict: true
      )
    end

    def self.from_ruby_llm(usage, model)
      require "ruby_llm"

      model_info = ::RubyLLM.models.find(model) if model
      return new unless model_info

      if defined?(::RubyLLM::Cost)
        tokens = ::RubyLLM::Tokens.new(
          input: usage.input_tokens,
          output: usage.output_tokens,
          cached: usage.cached_tokens,
          cache_creation: usage.cache_write_tokens,
          thinking: usage.thinking_tokens
        )
        from_hash(::RubyLLM::Cost.new(tokens: tokens, model: model_info).to_h)
      else
        from_rates(
          usage,
          input: model_info.input_price_per_million,
          output: model_info.output_price_per_million,
          cached_input: model_info.pricing&.text_tokens&.cached_input
        )
      end
    rescue LoadError, StandardError
      new
    end

    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_sym)
      new(
        input: hash[:input],
        output: hash[:output],
        cache_read: hash[:cache_read] || hash[:cached_input],
        cache_write: hash[:cache_write] || hash[:cache_creation],
        thinking: hash[:thinking] || hash[:reasoning] || hash[:thinking_output] || hash[:reasoning_output],
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
