# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TechnicalExplainer
  class ParallelClient
    API_BASE = "https://api.parallel.ai"

    def initialize(api_key: ENV["PARALLEL_API_KEY"], api_base: API_BASE)
      @api_key = api_key
      @api_base = api_base
    end

    def search(objective:, search_queries:, session_id: nil)
      post("/v1/search", {
        objective: objective,
        search_queries: Array(search_queries),
        session_id: session_id
      }.compact)
    end

    def extract(urls:, objective:, search_queries: nil, session_id: nil)
      post("/v1/extract", {
        urls: expand_urls(urls),
        objective: objective,
        search_queries: search_queries,
        session_id: session_id
      }.compact)
    end

    private
      def expand_urls(urls)
        Array(urls).flat_map do |url|
          url = url.to_s
          arxiv_id = url[%r{\Ahttps?://arxiv\.org/abs/([^?#]+)}, 1]
          arxiv_id ? [ url, "https://arxiv.org/pdf/#{arxiv_id}" ] : [ url ]
        end.uniq
      end

      def post(path, payload)
        raise ArgumentError, "PARALLEL_API_KEY is required" if @api_key.to_s.empty?

        uri = URI.join(@api_base, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["x-api-key"] = @api_key
        request.body = JSON.generate(payload)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end

        body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        return body if response.is_a?(Net::HTTPSuccess)

        message = body.is_a?(Hash) ? body.dig("error", "message") : nil
        raise "Parallel API #{response.code}: #{message || response.body}"
      end
  end
end
