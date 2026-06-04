# frozen_string_literal: true

module TurnKit
  class Usage
    attr_reader :input_tokens, :output_tokens, :cached_tokens, :cost

    def initialize(input_tokens: 0, output_tokens: 0, cached_tokens: 0, cost: nil)
      @input_tokens = input_tokens.to_i
      @output_tokens = output_tokens.to_i
      @cached_tokens = cached_tokens.to_i
      @cost = cost
    end

    def total_tokens
      input_tokens + output_tokens + cached_tokens
    end

    def to_h
      {
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "cached_tokens" => cached_tokens,
        "total_tokens" => total_tokens,
        "cost" => cost
      }.compact
    end
  end
end
