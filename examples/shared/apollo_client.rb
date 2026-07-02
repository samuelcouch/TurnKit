# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TurnKitExamples
  class ApolloClient
    API_BASE = "https://api.apollo.io/api/v1/"

    def initialize(api_key: ENV["APOLLO_API_KEY"], api_base: API_BASE, open_timeout: 5, read_timeout: 45)
      @api_key = api_key
      @api_base = api_base
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Finds net-new people in Apollo by title, seniority, company domain, location,
    # and email status. Apollo docs state this endpoint does not consume credits and
    # does not return emails/phones; use people_enrichment for contact details.
    def people_search(person_titles: nil, include_similar_titles: nil, q_keywords: nil, person_locations: nil, person_seniorities: nil, organization_locations: nil, organization_domains: nil, contact_email_status: nil, organization_ids: nil, organization_num_employees_ranges: nil, revenue_min: nil, revenue_max: nil, page: nil, per_page: nil, **extra_params)
      post("mixed_people/api_search", params: extra_params.merge({
        "person_titles[]" => person_titles,
        include_similar_titles: include_similar_titles,
        q_keywords: q_keywords,
        "person_locations[]" => person_locations,
        "person_seniorities[]" => person_seniorities,
        "organization_locations[]" => organization_locations,
        "q_organization_domains_list[]" => organization_domains,
        "contact_email_status[]" => contact_email_status,
        "organization_ids[]" => organization_ids,
        "organization_num_employees_ranges[]" => organization_num_employees_ranges,
        "revenue_range[min]" => revenue_min,
        "revenue_range[max]" => revenue_max,
        page: page,
        per_page: per_page
      }))
    end

    # Finds companies in Apollo. This endpoint consumes credits according to Apollo's
    # plan rules, so prefer Parallel/Hunter discovery unless Apollo company data is needed.
    def organization_search(organization_domains: nil, organization_name: nil, organization_ids: nil, organization_locations: nil, organization_num_employees_ranges: nil, keyword_tags: nil, revenue_min: nil, revenue_max: nil, page: nil, per_page: nil, **extra_params)
      post("mixed_companies/search", params: extra_params.merge({
        "q_organization_domains_list[]" => organization_domains,
        q_organization_name: organization_name,
        "organization_ids[]" => organization_ids,
        "organization_locations[]" => organization_locations,
        "organization_num_employees_ranges[]" => organization_num_employees_ranges,
        "q_organization_keyword_tags[]" => keyword_tags,
        "revenue_range[min]" => revenue_min,
        "revenue_range[max]" => revenue_max,
        page: page,
        per_page: per_page
      }))
    end

    # Enriches one person. Pass id from people_search when available for best matching.
    # run_waterfall_email/phone and reveal_* params may consume additional credits.
    def people_enrichment(first_name: nil, last_name: nil, name: nil, email: nil, hashed_email: nil, organization_name: nil, domain: nil, id: nil, linkedin_url: nil, run_waterfall_email: nil, run_waterfall_phone: nil, reveal_personal_emails: nil, reveal_phone_number: nil, webhook_url: nil)
      post("people/match", params: {
        first_name: first_name,
        last_name: last_name,
        name: name,
        email: email,
        hashed_email: hashed_email,
        organization_name: organization_name,
        domain: domain,
        id: id,
        linkedin_url: linkedin_url,
        run_waterfall_email: run_waterfall_email,
        run_waterfall_phone: run_waterfall_phone,
        reveal_personal_emails: reveal_personal_emails,
        reveal_phone_number: reveal_phone_number,
        webhook_url: webhook_url
      })
    end

    # Enriches up to 10 people in one request. Each details item can include fields
    # accepted by people_enrichment, such as id, name, domain, email, or linkedin_url.
    def bulk_people_enrichment(details:, run_waterfall_email: nil, run_waterfall_phone: nil, reveal_personal_emails: nil, reveal_phone_number: nil, webhook_url: nil)
      post("people/bulk_match", params: {
        run_waterfall_email: run_waterfall_email,
        run_waterfall_phone: run_waterfall_phone,
        reveal_personal_emails: reveal_personal_emails,
        reveal_phone_number: reveal_phone_number,
        webhook_url: webhook_url
      }, payload: { details: details })
    end

    def organization_enrichment(domain: nil, linkedin_url: nil, name: nil, website: nil)
      get("organizations/enrich", {
        domain: domain,
        linkedin_url: linkedin_url,
        name: name,
        website: website
      })
    end

    def bulk_organization_enrichment(details:)
      post("organizations/bulk_enrich", payload: { details: details })
    end

    def poll_webhook_result(request_id:)
      get("webhook_result/#{escape_path(request_id)}")
    end

    def usage_stats
      post("usage_stats/api_usage_stats")
    end

    private
      def get(path, params = {})
        request(:get, path, params: params)
      end

      def post(path, params: {}, payload: nil)
        request(:post, path, params: params, payload: payload)
      end

      def request(method, path, params: {}, payload: nil)
        raise ArgumentError, "APOLLO_API_KEY is required for Apollo API tools" if @api_key.to_s.empty?

        uri = build_uri(path, params)
        http_method = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = http_method.new(uri)
        request["Accept"] = "application/json"
        request["X-Api-Key"] = @api_key

        if method == :post
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload || {})
        end

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(request)
        end

        body = parse_body(response.body)
        return body if response.is_a?(Net::HTTPSuccess)

        raise "Apollo API #{response.code}: #{error_message(body) || response.body}"
      end

      def build_uri(path, params)
        uri = URI.join(@api_base, path)
        query = query_pairs(params)
        uri.query = URI.encode_www_form(query) unless query.empty?
        uri
      end

      def query_pairs(params)
        params.compact.flat_map do |key, value|
          next [] if value.to_s.empty?

          value.is_a?(Array) ? value.reject { |item| item.to_s.empty? }.map { |item| [key, item] } : [[key, value]]
        end
      end

      def parse_body(body)
        body.to_s.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        body.to_s
      end

      def error_message(body)
        return unless body.is_a?(Hash)

        errors = body["errors"]
        return errors.map { |error| error["message"] || error["details"] || error["id"] }.join("; ") if errors.is_a?(Array)

        error = body["error"]
        error_message = error.is_a?(Hash) ? error["message"] : error
        error_message || body["message"]
      end

      def escape_path(value)
        URI.encode_www_form_component(value.to_s)
      end
  end
end
