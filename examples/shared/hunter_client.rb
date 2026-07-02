# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TurnKitExamples
  class HunterClient
    API_BASE = "https://api.hunter.io/v2/"

    def initialize(api_key: ENV["HUNTER_API_KEY"], api_base: API_BASE, open_timeout: 5, read_timeout: 30)
      @api_key = api_key
      @api_base = api_base
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Free company discovery endpoint. Accepts either a natural-language query
    # or Hunter's structured filter body, e.g. { organization: { domain: [...] } }.
    def discover(query: nil, filters: nil, limit: nil, offset: nil)
      payload = (filters || {}).merge({ query: query, limit: limit, offset: offset }.compact)
      post("discover", payload)
    end

    # Returns emails associated with a company domain or name. Use type: "personal"
    # to avoid generic inboxes, and verification_status: "valid" for stricter output.
    def domain_search(domain: nil, company: nil, limit: nil, offset: nil, type: nil, seniority: nil, department: nil, required_field: nil, verification_status: nil)
      get("domain-search", {
        domain: domain,
        company: company,
        limit: limit,
        offset: offset,
        type: type,
        seniority: csv(seniority),
        department: csv(department),
        required_field: csv(required_field),
        verification_status: csv(verification_status)
      })
    end

    # Finds and verifies the most likely email for a named person at a company.
    # Hunter does not charge a credit when no email is found.
    def email_finder(domain: nil, company: nil, linkedin_handle: nil, first_name: nil, last_name: nil, full_name: nil, max_duration: nil)
      get("email-finder", {
        domain: domain,
        company: company,
        linkedin_handle: linkedin_handle,
        first_name: first_name,
        last_name: last_name,
        full_name: full_name,
        max_duration: max_duration
      })
    end

    # Verifies deliverability for a candidate email. Hunter can return HTTP 202
    # while verification is still running; poll this same method again for the result.
    def email_verifier(email:)
      get("email-verifier", { email: email })
    end

    def email_enrichment(email: nil, linkedin_handle: nil, clearbit_format: nil)
      get("people/find", {
        email: email,
        linkedin_handle: linkedin_handle,
        clearbit_format: clearbit_format
      })
    end

    def company_enrichment(domain:, clearbit_format: nil)
      get("companies/find", {
        domain: domain,
        clearbit_format: clearbit_format
      })
    end

    def combined_enrichment(email:, clearbit_format: nil)
      get("combined/find", {
        email: email,
        clearbit_format: clearbit_format
      })
    end

    def email_count(domain: nil, company: nil, type: nil)
      get("email-count", {
        domain: domain,
        company: company,
        type: type
      })
    end

    def account
      get("account")
    end

    private
      def get(path, params = {})
        request(:get, path, params: params)
      end

      def post(path, payload)
        request(:post, path, payload: payload)
      end

      def request(method, path, params: {}, payload: nil)
        raise ArgumentError, "HUNTER_API_KEY is required for Hunter API tools" if @api_key.to_s.empty?

        uri = build_uri(path, params)
        http_method = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = http_method.new(uri)
        request["Accept"] = "application/json"
        request["X-API-KEY"] = @api_key

        if method == :post
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload || {})
        end

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(request)
        end

        body = parse_body(response.body)
        return body if response.is_a?(Net::HTTPSuccess)

        raise "Hunter API #{response.code}: #{error_message(body) || response.body}"
      end

      def build_uri(path, params)
        uri = URI.join(@api_base, path)
        query = params.compact.reject { |_key, value| value.to_s.empty? }
        uri.query = URI.encode_www_form(query) unless query.empty?
        uri
      end

      def parse_body(body)
        body.to_s.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        body.to_s
      end

      def error_message(body)
        return unless body.is_a?(Hash)

        errors = body["errors"]
        return errors.map { |error| error["details"] || error["id"] }.join("; ") if errors.is_a?(Array)

        body.dig("error", "message") || body["message"]
      end

      def csv(value)
        value.is_a?(Array) ? value.join(",") : value
      end
  end
end
