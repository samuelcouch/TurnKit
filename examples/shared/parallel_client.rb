# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TurnKitExamples
  class ParallelClient
    API_BASE = "https://api.parallel.ai"

    def initialize(api_key: ENV["PARALLEL_API_KEY"], api_base: API_BASE, open_timeout: 5, read_timeout: 45)
      @api_key = api_key
      @api_base = api_base
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def search(objective:, search_queries:, session_id: nil)
      post("/v1/search", {
        objective: objective,
        search_queries: Array(search_queries),
        session_id: session_id
      }.compact)
    end

    def read_page(url:, objective:)
      read_pages(urls: [url], objective: objective)
    end

    def read_pages(urls:, objective:)
      extract(urls: urls, objective: objective)
    end

    def extract(urls:, objective:, search_queries: nil, session_id: nil)
      post("/v1/extract", {
        urls: expand_urls(urls),
        objective: objective,
        search_queries: search_queries,
        session_id: session_id
      }.compact)
    end

    def create_task_run(input:, task_spec:, processor:)
      post("/v1/tasks/runs", {
        input: input,
        task_spec: task_spec,
        processor: processor
      })
    end

    def task_run_result(run_id:)
      get("/v1/tasks/runs/#{escape_path(run_id)}/result")
    end

    def task_run_retrieve(run_id:)
      get("/v1/tasks/runs/#{escape_path(run_id)}")
    end

    def findall_ingest(objective:)
      post("/v1beta/findall/ingest", { objective: objective })
    end

    def findall_create(objective:, entity_type:, match_conditions:, generator:, match_limit:, enrichments: nil, metadata: nil)
      post("/v1beta/findall/runs", {
        objective: objective,
        entity_type: entity_type,
        match_conditions: match_conditions,
        generator: generator,
        match_limit: match_limit,
        enrichments: enrichments,
        metadata: metadata
      }.compact)
    end

    def findall_retrieve(findall_id:)
      get("/v1beta/findall/runs/#{escape_path(findall_id)}")
    end

    def findall_result(findall_id:)
      get("/v1beta/findall/runs/#{escape_path(findall_id)}/result")
    end

    def entity_search(entity_type:, objective:, match_limit:)
      post("/v1beta/findall/entity-search", {
        entity_type: entity_type,
        objective: objective,
        match_limit: match_limit
      })
    end

    private
      def expand_urls(urls)
        Array(urls).flat_map do |url|
          url = url.to_s
          arxiv_id = url[%r{\Ahttps?://arxiv\.org/abs/([^?#]+)}, 1]
          arxiv_id ? [url, "https://arxiv.org/pdf/#{arxiv_id}"] : [url]
        end.uniq
      end

      def post(path, payload)
        raise ArgumentError, "PARALLEL_API_KEY is required for Parallel web tools" if @api_key.to_s.empty?

        uri = URI.join(@api_base, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["x-api-key"] = @api_key
        request.body = JSON.generate(payload)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(request)
        end

        body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        return body if response.is_a?(Net::HTTPSuccess)

        message = body.is_a?(Hash) ? body.dig("error", "message") : nil
        raise "Parallel API #{response.code}: #{message || response.body}"
      end

      def get(path)
        raise ArgumentError, "PARALLEL_API_KEY is required for Parallel web tools" if @api_key.to_s.empty?

        uri = URI.join(@api_base, path)
        request = Net::HTTP::Get.new(uri)
        request["x-api-key"] = @api_key

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(request)
        end

        body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        return body if response.is_a?(Net::HTTPSuccess)

        message = body.is_a?(Hash) ? body.dig("error", "message") : nil
        raise "Parallel API #{response.code}: #{message || response.body}"
      end

      def escape_path(value)
        URI.encode_www_form_component(value.to_s)
      end
  end
end
