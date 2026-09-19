# frozen_string_literal: true

require "net/http"
require "timeout"

module TurnKit
  module Adapters
    # Decisions transport only. Turn owns attempts, accounting, and recovery.
    class OpenRouterJev
      MODEL = "typesafe/jev-1.13"
      ENDPOINT = "https://openrouter.ai/api/alpha/decisions"

      def initialize(api_key:, billing_identity:)
        raise ConfigError, "OpenRouter API key is required" if api_key.to_s.empty?
        raise ConfigError, "OpenRouter billing identity is required" if billing_identity.to_s.empty?
        @api_key, @billing_identity = api_key, billing_identity
      end

      def inspect = "#<#{self.class.name}>"
      def identity = { "provider" => "openrouter", "endpoint" => ENDPOINT, "account" => @billing_identity, "schema" => 1 }
      def cost_model(model:) = "openrouter/#{model}"

      def validate!(model:, state:, questions:)
        raise InputError, "unsupported OpenRouter evaluation model" unless model == MODEL
        input = Evaluation.input!(state: state, questions: questions)
        raise InputError, "OpenRouter state cannot be null" if input["state"].nil?
        input["questions"].each_value do |question|
          valid = !question["instructions"].nil?
          criteria = question["criteria"]
          if question["type"] == "noul" && question.key?("criteria")
            valid &&= criteria.is_a?(Hash) && criteria.keys.sort == %w[false true] && criteria.values.none?(&:nil?)
          elsif question["type"] == "score"
            valid &&= criteria.none?(&:nil?)
          end
          raise InputError, "invalid OpenRouter question" unless valid
        end
        input
      end

      def evaluate(model:, state:, questions:, timeout:)
        raise ArgumentError, "timeout must be positive and finite" unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        input = validate!(model: model, state: state, questions: questions)
        uri = URI(ENDPOINT)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(input.merge("model" => model))
        response = Timeout.timeout(timeout) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
            http.max_retries = 0
            http.request(request)
          end
        end
        code = response.code.to_i
        begin
          value = JSON.parse(response.body)
        rescue JSON::ParserError
          value = nil
        end
        observed = observed_usage(value)
        returned_model = value["model"] if value.is_a?(Hash) && value["model"].is_a?(String)
        unless code.between?(200, 299)
          uncertain = code == 408 || code >= 500
          raise EvaluationError.new(uncertain ? :uncertain : :unavailable,
            retryable: uncertain || code == 429, retry_after: retry_delay(response["Retry-After"]),
            http_status: code, usage: observed, model: returned_model)
        end
        unless value.is_a?(Hash) && valid_cost?(value["usage"])
          raise EvaluationError.new(:malformed, usage: observed, model: returned_model)
        end
        # OpenRouter's envelope and optional charge are not part of Jev's closed
        # answer schema. Never synthesize its optional confidence/distributions.
        normalized = value.slice("model", "answers", "usage")
        normalized["usage"] = value["usage"].slice("input_tokens", "output_tokens")
        begin
          result = Evaluation.result!(normalized, questions: input.fetch("questions"))
        rescue EvaluationError
          raise EvaluationError.new(:malformed, usage: observed, model: returned_model), cause: nil
        end
        EvaluationResult.new(model: result.model, answers: result.answers, usage: observed)
      rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError, Net::HTTPBadResponse, Net::ProtocolError
        raise EvaluationError.new(:uncertain, retryable: true), cause: nil
      end

      private
        def valid_cost?(usage)
          return false unless usage.is_a?(Hash)
          return true unless usage.key?("cost")
          cost = usage["cost"]
          cost.is_a?(Numeric) && cost.finite? && cost >= 0
        end

        def observed_usage(value)
          usage = value["usage"] if value.is_a?(Hash)
          return unless usage.is_a?(Hash)
          tokens = Evaluation.usage(usage.slice("input_tokens", "output_tokens"))
          cost = usage["cost"] if valid_cost?(usage)
          return unless tokens || cost
          Usage.new(input_tokens: tokens&.input_tokens, output_tokens: tokens&.output_tokens, cost: cost)
        end

        def retry_delay(value)
          return unless value
          return value.to_f if value.match?(/\A\d+(\.\d+)?\z/)
          [Time.httpdate(value) - Clock.now, 0].max
        rescue ArgumentError
          nil
        end
    end
  end
end
