# frozen_string_literal: true

require "net/http"
require "timeout"

module TurnKit
  module Adapters
    class CloudflareJev
      MODEL = "typesafe/jev"

      def initialize(account_id:, api_token:)
        raise ConfigError, "Cloudflare account ID is required" unless account_id.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)
        raise ConfigError, "Cloudflare API token is required" if api_token.to_s.empty?
        @account_id, @api_token = account_id, api_token
      end

      def inspect = "#<#{self.class.name}>"

      # Include route/account, but never the bearer credential, in receipt identity.
      def identity = { "provider" => "cloudflare", "account" => @account_id, "schema" => 1 }
      def cost_model(model:) = "cloudflare/#{model}"

      def validate!(model:, state:, questions:)
        raise InputError, "unsupported Cloudflare evaluation model" unless model == MODEL
        Evaluation.input!(state: state, questions: questions)
      end

      def evaluate(model:, state:, questions:, timeout:)
        raise ArgumentError, "timeout must be positive and finite" unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        input = validate!(model: model, state: state, questions: questions)
        uri = URI("https://api.cloudflare.com/client/v4/accounts/#{@account_id}/ai/run")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(model: model, input: input)
        response = Timeout.timeout(timeout) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
            http.max_retries = 0
            http.request(request)
          end
        end
        code = response.code.to_i
        unless code.between?(200, 299)
          transient = [408, 429, 500, 502, 503, 504].include?(code)
          # Quota exhaustion is not transient capacity pressure.
          if code == 429
            errors = JSON.parse(response.body).fetch("errors", []) rescue []
            transient = false if Array(errors).any? { |error| error.is_a?(Hash) && error["code"] == 3036 }
          end
          delay = retry_delay(response["Retry-After"])
          raise EvaluationError.new(code >= 500 || code == 408 ? :uncertain : :unavailable,
            retryable: transient, retry_after: delay, http_status: code)
        end
        value = JSON.parse(response.body)
        if value.is_a?(Hash) && value.key?("result")
          raise EvaluationError.new(:unavailable) unless value["success"] == true
          value = value["result"]
        end
        Evaluation.result!(value, questions: input.fetch("questions"))
      rescue JSON::ParserError
        raise EvaluationError.new(:malformed), cause: nil
      rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, SocketError, Net::HTTPBadResponse, Net::ProtocolError
        raise EvaluationError.new(:uncertain, retryable: true), cause: nil
      end

      private
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
