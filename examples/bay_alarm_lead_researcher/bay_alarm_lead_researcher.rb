# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "time"
require "turnkit"
require_relative "../shared/parallel_client"
require_relative "../shared/model_registry"

module BayAlarmLeadResearcher
  DEFAULT_REQUEST = "Find 12 independent auto repair shops in Southern California for Bay Alarm commercial security outreach. Target owners, general managers, or operations managers."
  DEFAULT_MODEL = ENV.fetch("TURNKIT_MODEL", "gpt-5.6-sol")
  DEFAULT_REGION = "Southern California"
  DEFAULT_PROCESSOR = ENV.fetch("PARALLEL_TASK_PROCESSOR", "pro")
  DEFAULT_DEEP_PROCESSOR = ENV.fetch("PARALLEL_DEEP_PROCESSOR", "ultra")
  DEFAULT_GENERATOR = ENV.fetch("PARALLEL_FINDALL_GENERATOR", "pro")

  module Schemas
    module_function

    def json_schema(properties, required: properties.keys, description: nil)
      {
        type: "json",
        json_schema: {
          type: "object",
          description: description,
          properties: properties,
          required: required.map(&:to_s),
          additionalProperties: false
        }.compact
      }
    end

    def vertical_research
      json_schema({
        vertical_summary: {
          type: "string",
          description: "A concise summary of the vertical in the requested Southern California region and why it is relevant for commercial security outreach."
        },
        included_business_types: {
          type: "array",
          items: { type: "string" },
          description: "Specific business categories and synonyms to include when searching for accounts."
        },
        excluded_business_types: {
          type: "array",
          items: { type: "string" },
          description: "Business categories to exclude because they are poor fits, consumer-only, national-chain-heavy, or outside the requested vertical."
        },
        security_pain_points: {
          type: "array",
          items: { type: "string" },
          description: "Commercial alarm, video, fire, access control, monitoring, or after-hours security pain points."
        },
        buying_triggers: {
          type: "array",
          items: { type: "string" },
          description: "Events or signals that make a business more likely to buy or review security systems."
        },
        decision_maker_titles: {
          type: "array",
          items: { type: "string" },
          description: "Professional titles likely to own a security-system purchase for this vertical."
        },
        qualification_criteria: {
          type: "array",
          items: { type: "string" },
          description: "Concrete account-level criteria to use when deciding if a business is a qualified lead."
        },
        outreach_angles: {
          type: "array",
          items: { type: "string" },
          description: "Short, source-safe cold-email angles a Bay Alarm salesperson could use."
        },
        sources: {
          type: "array",
          items: { type: "string" },
          description: "Source URLs used to support the vertical research."
        }
      }, description: "Cited vertical research for Bay Alarm commercial-security prospecting.")
    end

    def account_enrichment
      json_schema({
        company_name: {
          type: "string",
          description: "The canonical company name."
        },
        website: {
          type: "string",
          description: "The company's primary website URL. Prefer the official site over directories. If unavailable, return an empty string."
        },
        domain: {
          type: "string",
          description: "The normalized website domain: no protocol, no path, no www., no @ symbol. If unavailable, return an empty string."
        },
        primary_location: {
          type: "string",
          description: "Street address or city/county for the relevant Southern California location."
        },
        business_category: {
          type: "string",
          description: "The specific business category within the user's vertical."
        },
        fit_signals: {
          type: "array",
          items: { type: "string" },
          description: "Source-backed signs this business is a plausible commercial-security prospect."
        },
        security_need_hypothesis: {
          type: "string",
          description: "A careful hypothesis for why Bay Alarm may be relevant. Mark as a hypothesis unless directly supported by a source."
        },
        likely_decision_maker_titles: {
          type: "array",
          items: { type: "string" },
          description: "Titles to search for at this account, such as owner, president, CEO, general manager, operations manager, facilities manager, security manager, fleet manager, yard manager, controller, or CFO."
        },
        bay_alarm_fit_score: {
          type: "integer",
          description: "Sales fit score from 0 to 100 based on physical-premise risk, geography, vertical fit, buying authority, and contactability."
        },
        fit_reason: {
          type: "string",
          description: "One or two sentences explaining the fit score."
        },
        suggested_outreach_angle: {
          type: "string",
          description: "One short, source-safe outreach angle for this business."
        },
        sources: {
          type: "array",
          items: { type: "string" },
          description: "Source URLs used for this account enrichment."
        }
      }, description: "Structured account enrichment for Bay Alarm sales prospecting.")
    end

    def decision_makers
      json_schema({
        contacts: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string", description: "Professional contact's full name, or an empty string if unavailable." },
              title: { type: "string", description: "Professional title or role relevance." },
              company: { type: "string", description: "Associated company." },
              company_domain: { type: "string", description: "Associated company domain without protocol, path, www., or @ symbol. Return an empty string if unavailable." },
              contact_type: { type: "string", enum: ["named_decision_maker", "named_influencer", "generic_routing_inbox", "unknown"], description: "Classify whether this is a real person likely to influence a physical-security purchase or only a generic routing contact. Prefer named_decision_maker contacts." },
              purchase_role: { type: "string", description: "How this person likely participates in a Bay Alarm purchase decision: economic buyer, operations buyer, security/facilities influencer, finance approver, routing contact, or unknown." },
              profile_url: { type: "string", description: "LinkedIn, company team page, bio page, or other professional source URL. Return an empty string if unavailable." },
              email: { type: "string", description: "Publicly listed or verified professional email only. Return an empty string if unavailable or unverified." },
              email_status: { type: "string", enum: ["public_source", "verified", "needs_verification", "unavailable"], description: "Email provenance. Use verified only when an external verifier/provider says verified." },
              email_source: { type: "string", description: "URL or provider name supporting the email. Return an empty string if unavailable." },
              direct_phone: { type: "string", description: "Direct work phone or extension if publicly listed. Return an empty string if unavailable. Do not use personal/home numbers." },
              phone_source: { type: "string", description: "URL or source supporting the direct work phone. Return an empty string if unavailable." },
              why_this_person: { type: "string", description: "Why this person is a plausible Bay Alarm buying contact."
              }
            },
            required: ["name", "title", "company", "company_domain", "contact_type", "purchase_role", "profile_url", "email", "email_status", "email_source", "direct_phone", "phone_source", "why_this_person"],
            additionalProperties: false
          },
          description: "Up to five contacts, prioritizing named decision-makers with exact professional contact info over generic routing inboxes."
        },
        search_notes: {
          type: "string",
          description: "Where you searched and what remains uncertain."
        },
        sources: {
          type: "array",
          items: { type: "string" },
          description: "Source URLs used for people/contact research."
        }
      }, description: "Professional decision-maker candidates with strict email provenance.")
    end
  end

  class LeadPack
    attr_reader :request, :vertical, :region, :vertical_brief, :accounts, :compliance_notes, :created_at

    def initialize(request:, vertical:, region:, vertical_brief:, accounts:, compliance_notes:)
      @request = request.to_s.strip
      @vertical = vertical.to_s.strip
      @region = region.to_s.strip
      @vertical_brief = vertical_brief.to_s.strip
      @accounts = Array(accounts).map { |account| normalize_hash(account) }
      @compliance_notes = Array(compliance_notes).map(&:to_s).map(&:strip).reject(&:empty?)
      @created_at = Time.now.utc
    end

    def violations
      messages = []
      messages << "vertical is required" if vertical.empty?
      messages << "region is required" if region.empty?
      messages << "vertical_brief is required" if vertical_brief.empty?
      messages << "at least one account is required" if accounts.empty?

      accounts.each_with_index do |account, index|
        prefix = "account #{index + 1}"
        messages << "#{prefix} company_name is required" if account["company_name"].to_s.strip.empty?
        messages << "#{prefix} score must be 0..100" unless account["score"].to_i.between?(0, 100)
        messages << "#{prefix} needs at least one source URL" if Array(account["sources"]).empty?

        Array(account["contacts"]).each_with_index do |contact, contact_index|
          status = contact["email_status"].to_s
          messages << "#{prefix} contact #{contact_index + 1} has invalid email_status" unless %w[public_source verified needs_verification unavailable].include?(status)
          email = contact["email"].to_s.strip
          if email.empty?
            messages << "#{prefix} contact #{contact_index + 1} should mark missing email unavailable or needs_verification" unless %w[needs_verification unavailable].include?(status)
          elsif !%w[public_source verified].include?(status)
            messages << "#{prefix} contact #{contact_index + 1} includes email without public_source or verified status"
          end
        end
      end

      messages
    end

    def to_markdown
      <<~MARKDOWN.strip
        # Bay Alarm Lead Pack: #{vertical} in #{region}

        Generated: #{created_at.iso8601}

        ## Request
        #{request}

        ## Vertical Brief
        #{vertical_brief}

        ## Ranked Accounts
        #{accounts.each_with_index.map { |account, index| account_markdown(account, index + 1) }.join("\n\n")}

        ## Compliance Notes
        #{numbered_list(compliance_notes)}
      MARKDOWN
    end

    private
      def normalize_hash(value)
        value.to_h.transform_keys(&:to_s)
      end

      def account_markdown(account, number)
        contacts = Array(account["contacts"]).map { |contact| normalize_hash(contact) }
        <<~MARKDOWN.strip
          ### #{number}. #{account["company_name"]} — Score #{account["score"]}/100

          - Website: #{blank_to_na(account["website"])}
          - Domain: #{blank_to_na(account["domain"])}
          - Location: #{blank_to_na(account["location"])}
          - Fit reason: #{blank_to_na(account["fit_reason"])}
          - Outreach angle: #{blank_to_na(account["outreach_angle"])}
          - Next action: #{blank_to_na(account["next_action"])}
          - Sources: #{Array(account["sources"]).join(", ")}

          Contacts:
          #{contacts_markdown(contacts)}
        MARKDOWN
      end

      def contacts_markdown(contacts)
        return "- No professional contact found; verify via company website, LinkedIn, or approved contact-data provider." if contacts.empty?

        contacts.map do |contact|
          email = contact["email"].to_s.strip.empty? ? "email unavailable" : contact["email"]
          phone = contact["direct_phone"].to_s.strip.empty? ? "phone unavailable" : contact["direct_phone"]
          "- #{blank_to_na(contact["name"])} — #{blank_to_na(contact["title"])}; type=#{blank_to_na(contact["contact_type"])}; role=#{blank_to_na(contact["purchase_role"])}; #{email}; status=#{blank_to_na(contact["email_status"])}; #{phone}; source=#{blank_to_na(contact["email_source"] || contact["phone_source"] || contact["profile_url"])}; reason=#{blank_to_na(contact["why_this_person"])}"
        end.join("\n")
      end

      def numbered_list(values)
        values = Array(values).map(&:to_s).map(&:strip).reject(&:empty?)
        return "1. No additional notes." if values.empty?

        values.each_with_index.map { |value, index| "#{index + 1}. #{value}" }.join("\n")
      end

      def blank_to_na(value)
        text = value.to_s.strip
        text.empty? ? "N/A" : text
      end
  end

  module Tools
    module TaskResultWaiter
      private
        def wait_for_task(run_id)
          deadline = Time.now + Integer(ENV.fetch("PARALLEL_TASK_POLL_SECONDS", ENV.fetch("PARALLEL_TASK_RESULT_TIMEOUT", "7200")))
          interval = Float(ENV.fetch("PARALLEL_TASK_POLL_INTERVAL", ENV.fetch("PARALLEL_TASK_RESULT_DELAY", "10")))
          last_status = nil

          parallel_log("task #{run_id} polling started deadline=#{deadline.utc.iso8601} interval=#{interval}s")

          loop do
            status = @parallel_client.task_run_retrieve(run_id: run_id)
            state = task_state(status)
            if state != last_status
              parallel_log("task #{run_id} status=#{state} payload=#{compact_status(status)}")
              last_status = state
            else
              parallel_log("task #{run_id} status=#{state}") if verbose_parallel_polling?
            end

            case state
            when "completed"
              parallel_log("task #{run_id} completed; fetching result")
              return @parallel_client.task_run_result(run_id: run_id)
            when "failed", "cancelled", "canceled"
              raise "Parallel task #{run_id} ended with status #{state}: #{compact_status(status)}"
            end

            raise "Parallel task #{run_id} still active after polling timeout" if Time.now >= deadline

            sleep interval
          end
        end

        def task_state(status)
          status["status"].is_a?(Hash) ? status.dig("status", "status").to_s : status["status"].to_s
        end

        def compact_status(status)
          status.to_h.slice("run_id", "status", "processor", "created_at", "modified_at", "error")
        end

        def parallel_log(message)
          warn "[parallel] #{Time.now.utc.iso8601} #{message}"
        end

        def verbose_parallel_polling?
          ENV["PARALLEL_VERBOSE_POLLING"] || ENV["VERBOSE"]
        end
    end

    class ResearchVertical < TurnKit::Tool
      include TaskResultWaiter

      tool_name "research_vertical"
      description "Run a cited Parallel Task API research pass for one vertical and region."
      usage_hint "Use first to understand security pain points, buying triggers, decision-maker titles, and qualification criteria before finding companies. This example is quality-first: use ultra by default for vertical research. Do not choose -fast processors unless the user explicitly asks for speed or a smoke test."
      parameter :vertical, :string, required: true, description: "The vertical or industry to research."
      parameter :region, :string, required: true, description: "Geography to focus on. Default to Southern California when unspecified."
      parameter :sales_context, :string, required: true, description: "The Bay Alarm sales context and any user constraints. Include the requested lead count, target account type, target roles, exclusions, and whether this is a smoke test or production-quality research pass."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast pro pro-fast ultra ultra-fast], default: DEFAULT_DEEP_PROCESSOR, description: "Parallel processor to use. Use ultra by default for quality-first vertical research. Use pro if a blocking run needs to stay shorter. Use -fast only for explicit speed/smoke-test requests."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(vertical:, region:, sales_context:, processor: DEFAULT_DEEP_PROCESSOR, context:)
        input = {
          vertical: vertical,
          region: region,
          sales_context: sales_context,
          task: "Research this vertical as a Bay Alarm commercial-security prospecting segment. Use current web sources and cite sources."
        }

        run = @parallel_client.create_task_run(
          input: input,
          task_spec: { output_schema: Schemas.vertical_research },
          processor: processor
        )
        parallel_log("research_vertical created run_id=#{run.fetch("run_id")} processor=#{processor} vertical=#{vertical.inspect} region=#{region.inspect} sales_context=#{sales_context.inspect}")
        wait_for_task(run.fetch("run_id"))
      end
    end

    class DraftFindAllSchema < TurnKit::Tool
      tool_name "draft_findall_schema"
      description "Ask Parallel FindAll ingest to draft entity type and match conditions from a natural-language account discovery objective."
      usage_hint "Use this before find_companies when you want a starting schema, then adjust the match conditions yourself before creating the run."
      parameter :objective, :string, required: true, description: "Natural-language account discovery objective."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(objective:, context:)
        @parallel_client.findall_ingest(objective: objective)
      end
    end

    class FindCompanies < TurnKit::Tool
      include TaskResultWaiter

      tool_name "find_companies"
      description "Run Parallel FindAll to discover and evaluate matching company prospects."
      usage_hint "Use after vertical research. This is the main discovery pass and should normally be called exactly once. Before calling, consolidate all vertical synonyms, target geographies, multi-location preference, exclusions, and quality criteria into one objective and one set of match conditions. Use generator=pro by default. Do not make repeated exploratory FindAll calls; refine downstream with account enrichment unless the first call explicitly fails or returns unusably empty results."
      parameter :objective, :string, required: true, description: "Natural-language description of the company prospects to find."
      parameter :match_conditions, :array, required: true, items: {
        type: "object",
        properties: {
          name: { type: "string" },
          description: { type: "string" }
        },
        required: ["name", "description"],
        additionalProperties: false
      }, description: "FindAll match conditions. Each must have name and description."
      parameter :match_limit, :integer, required: false, default: 12, description: "Maximum matched companies to return."
      parameter :generator, :enum, required: false, enum: %w[preview base core pro], default: DEFAULT_GENERATOR, description: "FindAll generator tier. Use pro by default for highest-quality discovery. Use preview/base/core only for explicit testing, cost, or speed constraints."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(objective:, match_conditions:, match_limit: 12, generator: DEFAULT_GENERATOR, context:)
        run = @parallel_client.findall_create(
          objective: objective,
          entity_type: "companies",
          match_conditions: normalize_conditions(match_conditions),
          generator: generator,
          match_limit: match_limit,
          metadata: { source: "turnkit-bay-alarm-example" }
        )
        findall_id = run.fetch("findall_id")
        parallel_log("find_companies created findall_id=#{findall_id} generator=#{generator} match_limit=#{match_limit}")
        poll_findall(findall_id)
        compact_result(@parallel_client.findall_result(findall_id: findall_id), match_limit: match_limit)
      end

      private
        def compact_result(result, match_limit:)
          candidates = Array(result["candidates"])
            .select { |candidate| candidate["match_status"].to_s.empty? || candidate["match_status"] == "matched" }
            .first(match_limit.to_i)
            .map { |candidate| compact_candidate(candidate) }

          {
            findall_id: result["findall_id"],
            status: result["status"],
            candidates: candidates
          }
        end

        def compact_candidate(candidate)
          output = candidate["output"] || {}
          url = candidate["url"].to_s
          {
            candidate_id: candidate["candidate_id"],
            name: candidate["name"],
            url: candidate["url"],
            domain: domain_from_url(url),
            description: candidate["description"],
            match_status: candidate["match_status"],
            match_evidence: compact_output(output),
            source_urls: source_urls_from(candidate).first(8)
          }
        end

        def compact_output(output)
          output.to_h.transform_values do |value|
            hash = value.respond_to?(:to_h) ? value.to_h : { "value" => value }
            {
              value: hash["value"].to_s[0, 500],
              is_matched: hash["is_matched"]
            }.compact
          end
        end

        def source_urls_from(value)
          case value
          when Hash
            value.flat_map do |key, nested|
              urls = []
              urls << nested if key.to_s.match?(/url/i) && nested.is_a?(String) && nested.start_with?("http")
              urls + source_urls_from(nested)
            end
          when Array
            value.flat_map { |nested| source_urls_from(nested) }
          when String
            value.scan(%r!https?://[^\s)\]}"']+!)
          else
            []
          end.uniq
        end

        def domain_from_url(url)
          host = URI(url).host.to_s.downcase
          host.sub(/\Awww\./, "")
        rescue URI::InvalidURIError
          ""
        end

        def normalize_conditions(conditions)
          Array(conditions).map do |condition|
            hash = condition.to_h.transform_keys(&:to_s)
            {
              name: hash.fetch("name"),
              description: hash.fetch("description")
            }
          end
        end

        def poll_findall(findall_id)
          deadline = Time.now + Integer(ENV.fetch("PARALLEL_FINDALL_POLL_SECONDS", "1800"))
          interval = Float(ENV.fetch("PARALLEL_FINDALL_POLL_INTERVAL", "5"))
          last_state = nil

          loop do
            status = @parallel_client.findall_retrieve(findall_id: findall_id)
            state = status.dig("status", "status").to_s
            if state != last_state
              warn "[parallel] #{Time.now.utc.iso8601} findall #{findall_id} status=#{state} metrics=#{status.dig("status", "metrics").inspect}"
              last_state = state
            elsif ENV["PARALLEL_VERBOSE_POLLING"] || ENV["VERBOSE"]
              warn "[parallel] #{Time.now.utc.iso8601} findall #{findall_id} status=#{state}"
            end
            return status if state == "completed" || (!status.dig("status", "is_active") && state.empty?)
            raise "FindAll run #{findall_id} ended with status #{state}" if %w[failed cancelled].include?(state)
            raise "FindAll run #{findall_id} still active after polling timeout" if Time.now >= deadline

            sleep interval
          end
        end
    end

    class SearchEntities < TurnKit::Tool
      tool_name "search_entities"
      description "Run fast Parallel Entity Search for people or companies."
      usage_hint "Use for quick candidate lookup or when FindAll is overkill. This returns ranked candidates without per-field citations."
      parameter :entity_type, :enum, required: true, enum: %w[people companies], description: "Entity kind to search."
      parameter :objective, :string, required: true, description: "Natural-language description of entities to find."
      parameter :match_limit, :integer, required: false, default: 10, description: "Maximum candidates to return, between 5 and 1000."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(entity_type:, objective:, match_limit: 10, context:)
        @parallel_client.entity_search(entity_type: entity_type, objective: objective, match_limit: match_limit)
      end
    end

    class EnrichAccount < TurnKit::Tool
      include TaskResultWaiter

      tool_name "enrich_account"
      description "Use Parallel Task API to enrich one candidate company for Bay Alarm fit, sources, and outreach angle."
      usage_hint "Use for promising companies from FindAll before deciding which accounts make the final lead pack."
      parameter :company_name, :string, required: true, description: "Company name to enrich."
      parameter :website, :string, required: false, description: "Company website URL, if known."
      parameter :domain, :string, required: false, description: "Normalized company domain, without protocol, path, www., or @ symbol."
      parameter :vertical, :string, required: true, description: "Target vertical."
      parameter :region, :string, required: true, description: "Target region."
      parameter :known_context, :string, required: false, description: "Candidate description, source notes, or fit clues from FindAll."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast core2x core2x-fast pro pro-fast], default: DEFAULT_PROCESSOR, description: "Parallel processor to use. Use pro by default for quality-first account enrichment. Use -fast only for explicit speed/smoke-test requests."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(company_name:, vertical:, region:, website: nil, domain: nil, known_context: nil, processor: DEFAULT_PROCESSOR, context:)
        input = {
          company_name: company_name,
          website: website,
          domain: domain,
          vertical: vertical,
          region: region,
          known_context: known_context,
          task: "Enrich this account as a Bay Alarm commercial-security sales prospect. Use current web sources. Do not invent facts. Verify or recover the official website and normalized bare domain for contact research."
        }.compact

        run = @parallel_client.create_task_run(
          input: input,
          task_spec: { output_schema: Schemas.account_enrichment },
          processor: processor
        )
        parallel_log("enrich_account created run_id=#{run.fetch("run_id")} processor=#{processor} company=#{company_name.inspect}")
        wait_for_task(run.fetch("run_id"))
      end
    end

    class EnrichAccounts < TurnKit::Tool
      include TaskResultWaiter

      MAX_BATCH = 8

      tool_name "enrich_accounts"
      description "Use Parallel Task API to enrich multiple company candidates concurrently for Bay Alarm fit, sources, and outreach angles."
      usage_hint "Prefer this over repeated enrich_account calls when enriching several candidates from FindAll. Keep the batch to the best candidates only."
      parameter :accounts, :array, required: true, items: {
        type: "object",
        properties: {
          company_name: { type: "string" },
          website: { type: "string" },
          domain: { type: "string" },
          known_context: { type: "string" }
        },
        required: ["company_name"],
        additionalProperties: false
      }, description: "Accounts to enrich, up to 8. Each account should include company_name and, when known, website and context."
      parameter :vertical, :string, required: true, description: "Target vertical."
      parameter :region, :string, required: true, description: "Target region."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast core2x core2x-fast pro pro-fast], default: DEFAULT_PROCESSOR, description: "Parallel processor to use. Use pro by default for quality-first account enrichment. Use -fast only for explicit speed/smoke-test requests."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(accounts:, vertical:, region:, processor: DEFAULT_PROCESSOR, context:)
        accounts = Array(accounts).first(MAX_BATCH).map { |account| account.to_h.transform_keys(&:to_s) }
        threads = accounts.map do |account|
          Thread.new { enrich_one(account, vertical: vertical, region: region, processor: processor) }
        end

        { accounts: threads.map(&:value) }
      end

      private
        def enrich_one(account, vertical:, region:, processor:)
          input = {
            company_name: account.fetch("company_name"),
            website: account["website"],
            domain: account["domain"],
            vertical: vertical,
            region: region,
            known_context: account["known_context"],
            task: "Enrich this account as a Bay Alarm commercial-security sales prospect. Use current web sources. Do not invent facts. Verify or recover the official website and normalized bare domain for contact research."
          }.compact

          run = @parallel_client.create_task_run(
            input: input,
            task_spec: { output_schema: Schemas.account_enrichment },
            processor: processor
          )
          parallel_log("enrich_accounts created run_id=#{run.fetch("run_id")} processor=#{processor} company=#{account.fetch("company_name").inspect}")
          {
            company_name: account.fetch("company_name"),
            result: wait_for_task(run.fetch("run_id"))
          }
        rescue StandardError => error
          {
            company_name: account["company_name"],
            error: { class: error.class.name, message: error.message }
          }
        end
    end

    class FindDecisionMakers < TurnKit::Tool
      include TaskResultWaiter

      tool_name "find_decision_makers"
      description "Find exact professional contact info for named decision-makers likely to buy or influence physical-security systems at one company."
      usage_hint "Use only for qualified accounts. Use pro by default because contact research needs multi-source verification and role disambiguation. Prioritize real people: owner/CEO/president, operations leader, general manager, facilities/security/yard/fleet/dispatch manager, controller/CFO. Return direct public or verified professional emails and direct work phones when available. Generic inboxes are fallback routing contacts only. Never fabricate or pattern-guess emails."
      parameter :company_name, :string, required: true, description: "Company name."
      parameter :website, :string, required: false, description: "Company website URL, if known."
      parameter :domain, :string, required: false, description: "Normalized company domain, without protocol, path, www., or @ symbol."
      parameter :target_roles, :array, required: true, items: :string, description: "Professional roles to look for."
      parameter :region, :string, required: true, description: "Relevant geography."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast core2x core2x-fast pro pro-fast], default: DEFAULT_PROCESSOR, description: "Parallel processor to use."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(company_name:, target_roles:, region:, website: nil, domain: nil, processor: DEFAULT_PROCESSOR, context:)
        input = {
          company_name: company_name,
          website: website,
          domain: domain,
          target_roles: target_roles,
          region: region,
          rules: "Professional context only. Use the normalized company domain when available as the strongest company identifier. Find exact named decision-makers first: owner/CEO/president, operations leader, GM, facilities/security/yard/fleet/dispatch manager, controller/CFO. Return profile URLs when available. Return direct public or verified professional emails and direct work phones when available. Generic inboxes are fallback routing contacts only and should use contact_type generic_routing_inbox. If no verified/public email is found for a named person, return an empty email string and email_status unavailable or needs_verification. Never fabricate or pattern-guess emails."
        }.compact

        run = @parallel_client.create_task_run(
          input: input,
          task_spec: { output_schema: Schemas.decision_makers },
          processor: processor
        )
        parallel_log("find_decision_makers created run_id=#{run.fetch("run_id")} processor=#{processor} company=#{company_name.inspect}")
        wait_for_task(run.fetch("run_id"))
      end
    end

    class FindDecisionMakersBatch < TurnKit::Tool
      include TaskResultWaiter

      MAX_BATCH = 8

      tool_name "find_decision_makers_batch"
      description "Find exact professional contact info for named decision-makers likely to buy or influence physical-security systems at multiple companies concurrently."
      usage_hint "Prefer this over repeated find_decision_makers calls for final shortlisted accounts. Use pro by default because contact research needs multi-source verification and role disambiguation. Prioritize real people: owner/CEO/president, operations leader, general manager, facilities/security/yard/fleet/dispatch manager, controller/CFO. Return direct public or verified professional emails and direct work phones when available. Generic inboxes are fallback routing contacts only. Never fabricate or pattern-guess emails."
      parameter :accounts, :array, required: true, items: {
        type: "object",
        properties: {
          company_name: { type: "string" },
          website: { type: "string" },
          domain: { type: "string" }
        },
        required: ["company_name"],
        additionalProperties: false
      }, description: "Qualified accounts to research, up to 8. Include normalized domain when available so provider lookup can match the exact company."
      parameter :target_roles, :array, required: true, items: :string, description: "Professional roles to look for."
      parameter :region, :string, required: true, description: "Relevant geography."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast core2x core2x-fast pro pro-fast], default: DEFAULT_PROCESSOR, description: "Parallel processor to use."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(accounts:, target_roles:, region:, processor: DEFAULT_PROCESSOR, context:)
        accounts = Array(accounts).first(MAX_BATCH).map { |account| account.to_h.transform_keys(&:to_s) }
        threads = accounts.map do |account|
          Thread.new { find_for_one(account, target_roles: target_roles, region: region, processor: processor) }
        end

        { accounts: threads.map(&:value) }
      end

      private
        def find_for_one(account, target_roles:, region:, processor:)
          input = {
            company_name: account.fetch("company_name"),
            website: account["website"],
            domain: account["domain"],
            target_roles: target_roles,
            region: region,
            rules: "Professional context only. Use the normalized company domain when available as the strongest company identifier. Find exact named decision-makers first: owner/CEO/president, operations leader, GM, facilities/security/yard/fleet/dispatch manager, controller/CFO. Return profile URLs when available. Return direct public or verified professional emails and direct work phones when available. Generic inboxes are fallback routing contacts only and should use contact_type generic_routing_inbox. If no verified/public email is found for a named person, return an empty email string and email_status unavailable or needs_verification. Never fabricate or pattern-guess emails."
          }.compact

          run = @parallel_client.create_task_run(
            input: input,
            task_spec: { output_schema: Schemas.decision_makers },
            processor: processor
          )
          parallel_log("find_decision_makers_batch created run_id=#{run.fetch("run_id")} processor=#{processor} company=#{account.fetch("company_name").inspect}")
          {
            company_name: account.fetch("company_name"),
            result: wait_for_task(run.fetch("run_id"))
          }
        rescue StandardError => error
          {
            company_name: account["company_name"],
            error: { class: error.class.name, message: error.message }
          }
        end
    end

    class SaveLeadPack < TurnKit::Tool
      tool_name "save_lead_pack"
      description "Save and render the final Bay Alarm lead pack. This ends the workflow."
      usage_hint "Use only after research, account discovery, enrichment, contact checks, and final self-verification are complete."
      parameter :request, :string, required: true, description: "Original user request."
      parameter :vertical, :string, required: true, description: "Vertical researched."
      parameter :region, :string, required: true, description: "Region researched."
      parameter :vertical_brief, :string, required: true, description: "Concise vertical research brief with source-backed sales insights."
      parameter :accounts, :array, required: true, items: {
        type: "object",
        properties: {
          company_name: { type: "string" },
          website: { type: "string" },
          domain: { type: "string" },
          location: { type: "string" },
          score: { type: "integer" },
          fit_reason: { type: "string" },
          outreach_angle: { type: "string" },
          next_action: { type: "string" },
          sources: { type: "array", items: { type: "string" } },
          contacts: { type: "array", items: { type: "object" } }
        },
        required: ["company_name", "website", "domain", "location", "score", "fit_reason", "outreach_angle", "next_action", "sources", "contacts"],
        additionalProperties: false
      }, description: "Ranked account lead cards, best accounts first."
      parameter :compliance_notes, :array, required: true, items: :string, description: "Compliance and data-quality caveats, especially around email provenance and opt-out requirements."

      terminal! { |result| result.fetch("lead_pack") }

      def call(request:, vertical:, region:, vertical_brief:, accounts:, compliance_notes:, context:)
        lead_pack = LeadPack.new(
          request: request,
          vertical: vertical,
          region: region,
          vertical_brief: vertical_brief,
          accounts: accounts,
          compliance_notes: compliance_notes
        )
        violations = lead_pack.violations
        raise TurnKit::ToolError, "lead pack failed validation: #{violations.join("; ")}" if violations.any?

        { lead_pack: lead_pack.to_markdown }
      end
    end
  end

  def self.tools(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))), include_research: true, include_entity_search: false)
    tools = []
    tools << Tools::ResearchVertical.new(parallel_client: parallel_client) if include_research
    tools += [
      Tools::DraftFindAllSchema.new(parallel_client: parallel_client),
      Tools::FindCompanies.new(parallel_client: parallel_client),
      Tools::EnrichAccount.new(parallel_client: parallel_client),
      Tools::EnrichAccounts.new(parallel_client: parallel_client),
      Tools::FindDecisionMakers.new(parallel_client: parallel_client),
      Tools::FindDecisionMakersBatch.new(parallel_client: parallel_client),
      Tools::SaveLeadPack
    ]
    tools.insert(3, Tools::SearchEntities.new(parallel_client: parallel_client)) if include_entity_search
    tools
  end
end

TurnKit.configure do |config|
  config.default_model = BayAlarmLeadResearcher::DEFAULT_MODEL
  TurnKitExamples.prepare_model(config.default_model)
  config.store = TurnKit::MemoryStore.new
  config.compaction = {
    context_limit: Integer(ENV.fetch("TURNKIT_CONTEXT_LIMIT", "96000")),
    threshold: 0.75
  }
  config.max_iterations = Integer(ENV.fetch("TURNKIT_MAX_ITERATIONS", "25"))
  config.max_tool_executions = Integer(ENV.fetch("TURNKIT_MAX_TOOL_EXECUTIONS", "80"))
  config.max_tool_executions_by_name = {
    "research_vertical" => Integer(ENV.fetch("TURNKIT_MAX_VERTICAL_RESEARCH", "1")),
    "draft_findall_schema" => Integer(ENV.fetch("TURNKIT_MAX_FINDALL_SCHEMA", "1")),
    "find_companies" => Integer(ENV.fetch("TURNKIT_MAX_FIND_COMPANIES", "3")),
    "search_entities" => Integer(ENV.fetch("TURNKIT_MAX_ENTITY_SEARCHES", "8")),
    "enrich_account" => Integer(ENV.fetch("TURNKIT_MAX_ACCOUNT_ENRICHMENTS", "12")),
    "enrich_accounts" => Integer(ENV.fetch("TURNKIT_MAX_ACCOUNT_BATCH_ENRICHMENTS", "2")),
    "find_decision_makers" => Integer(ENV.fetch("TURNKIT_MAX_CONTACT_SEARCHES", "12")),
    "find_decision_makers_batch" => Integer(ENV.fetch("TURNKIT_MAX_CONTACT_BATCH_SEARCHES", "2")),
    "save_lead_pack" => 1
  }
  config.timeout = Integer(ENV.fetch("TURNKIT_TIMEOUT", "900"))
end

events = []
TurnKit.on_event = ->(event) do
  events << event
  next unless ENV["VERBOSE"] || ENV["DEEP_MONITORING"] || %w[turn.started tool_call.completed turn.completed turn.failed].include?(event.type)

  warn "turnkit.#{event.type} turn=#{event.turn_id} payload=#{event.payload.inspect}"
end

request = ARGV.join(" ").strip
request = BayAlarmLeadResearcher::DEFAULT_REQUEST if request.empty?

parallel_client = TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180")))
skill = TurnKit::Skill.from_file(File.join(__dir__, "skills", "bay_alarm_outbound_research.md"))
cached_vertical_research = if ENV["BAY_ALARM_CACHED_VERTICAL_RESEARCH_FILE"].to_s.empty?
  nil
else
  JSON.parse(File.read(ENV.fetch("BAY_ALARM_CACHED_VERTICAL_RESEARCH_FILE")))
end

thinking_effort = ENV.fetch("TURNKIT_THINKING_EFFORT", TurnKit.default_model == "gpt-5.6-sol" ? "none" : "medium")
agent = TurnKit::Agent.new(
  name: "bay_alarm_lead_researcher",
  orchestrator: true,
  description: "Builds cited Bay Alarm cold-outbound lead packs for one Southern California vertical.",
  model: TurnKit.default_model,
  thinking: { effort: thinking_effort },
  skills: [skill],
  tools: BayAlarmLeadResearcher.tools(
    parallel_client: parallel_client,
    include_research: cached_vertical_research.nil?,
    include_entity_search: ENV["BAY_ALARM_ENABLE_ENTITY_SEARCH"] == "1"
  ),
  max_spend: Float(ENV.fetch("TURNKIT_MAX_SPEND", "3.00")),
  max_iterations: TurnKit.max_iterations,
  max_tool_executions: TurnKit.max_tool_executions,
  max_tool_executions_by_name: TurnKit.max_tool_executions_by_name,
  compaction: TurnKit.compaction,
  instructions: <<~TEXT
    You are a senior B2B sales research operator building lead packs for Bay Alarm.
    Bay Alarm sells commercial alarm systems, monitoring, video security, fire
    monitoring, access control, and related services. Use the configured model
    for planning, source judgment, fit scoring, and final synthesis; use Parallel
    tools for live web research, entity discovery, and structured enrichment.

    Critical rules:
    - If cached_vertical_research is provided in workflow input, vertical research
      is already complete. Do not call research_vertical; use the cached brief,
      criteria, decision-maker titles, and sources, then proceed to FindAll.
    - This example is configured for highest practical Parallel quality, not
      speed: use FindAll generator pro, Task processor pro for account/contact
      enrichment, and deep processor ultra for vertical research unless the user
      explicitly asks for a smoke test, lower cost, or speed.
    - Use FindAll for account discovery. Do not use search_entities in normal
      quality-first runs; it is only an explicit fallback when enabled.
    - Plan discovery before tool use. Call find_companies once for the main
      account discovery pass, with all synonyms, geographies, exclusions,
      multi-location preference, and website/domain requirements already folded
      into the objective and match_conditions. Do not issue multiple FindAll
      calls as iterative brainstorming.
    - Do not choose -fast Parallel processors in normal runs; fast modes trade
      off quality/freshness for latency and are only for explicit speed requests.
    - Research the vertical before finding companies.
    - Prefer quality and citation strength over list size.
    - Preserve identifiers for every account: canonical company
      name, official website URL, bare domain without www/protocol/path, and the
      relevant Southern California location.
    - Before contact research, ensure each shortlisted account has a domain when
      one can be found to distinguish companies with similar names.
    - When searching contacts, prioritize buyer titles: owner, president,
      CEO, dealer principal, GM, operations,
      facilities, security, fleet, yard, dispatch, controller, and CFO titles.
    - Treat Southern California as the default region when the request is broad.
    - Do not fabricate businesses, people, emails, source URLs, or buying signals.
    - Emails must be public_source or verified. If no approved verifier is used,
      do not mark anything verified.
    - Use save_lead_pack exactly once when the final answer is ready.
  TEXT
)

puts "Running Bay Alarm lead researcher..."
run = agent.run(
  "Create a sales-ready Bay Alarm lead pack for the request.",
  input: {
    request: request,
    default_region: BayAlarmLeadResearcher::DEFAULT_REGION,
    default_model: BayAlarmLeadResearcher::DEFAULT_MODEL,
    thinking_effort: thinking_effort,
    cached_vertical_research: cached_vertical_research
  }.compact
)

if run.failed?
  warn "Run failed: #{TurnKit.store.load_turn(run.id).fetch("error").inspect}"
  exit 1
end

puts
puts run.output_text
puts
puts "--- Run graph ---"
puts "turns: #{run.turn_records.map { |record| record.fetch("agent_name") }.join(" -> ")}"
puts "tools: #{run.tool_executions.map(&:tool_name).join(", ")}"
puts "tokens: #{run.usage.total_tokens}"
puts "cost: #{run.cost.total || "unknown"}"

if ENV["DEEP_MONITORING"]
  puts
  puts "--- Deep monitoring ---"
  puts "events: #{events.length}"
  events.each_with_index do |event, index|
    puts "%02d %-24s turn=%s payload=%s" % [index + 1, event.type, event.turn_id, event.payload.inspect]
  end

  puts
  puts "tool executions:"
  run.turn_records.each do |record|
    TurnKit.store.list_tool_executions(turn_id: record.fetch("id")).each do |execution|
      args = JSON.generate(execution["arguments"] || {})
      args = "#{args[0, 500]}..." if args.length > 500
      error = execution["error"] ? " error=#{execution["error"].inspect}" : ""
      puts "- #{execution.fetch("id")} turn=#{record.fetch("id")} tool=#{execution.fetch("tool_name")} status=#{execution.fetch("status")} args=#{args}#{error}"
    end
  end
end
