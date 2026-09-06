# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "time"
require "turnkit"
require_relative "../shared/parallel_client"
require_relative "../shared/model_registry"

module NeighborNameResearcher
  DEFAULT_REQUEST = "I live in Bryn Mawr, PA. My neighbors are Billy/William and his wife is Kelly/Kelli/Kelley. Kelly/Kelli/Kelley is a medical professional, likely at Bryn Mawr Hospital or in the Main Line Health network. Billy/William works in sales and has also coached hockey. Their daughter Grace was born around a year ago. Help me remember their last name for wedding invitations."
  DEFAULT_MODEL = ENV.fetch("TURNKIT_MODEL", "gpt-5.6-sol")
  DEFAULT_DEEP_PROCESSOR = ENV.fetch("PARALLEL_DEEP_PROCESSOR", "ultra")

  module Schemas
    module_function

    def deep_identity_research
      {
        type: "json",
        json_schema: {
          type: "object",
          description: "Privacy-minimized public-source identity recall research for a user-provided neighbor/family context.",
          properties: {
            candidates: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  last_name: { type: "string", description: "Candidate family last name, or empty string if no responsible candidate is supported." },
                  confidence: { type: "string", enum: %w[high medium low], description: "Confidence that this is the user's intended neighbor family." },
                  match_summary: { type: "string", description: "Short explanation of which user-provided facts match. Do not include street addresses, phone numbers, personal emails, birth dates, or unnecessary minor details." },
                  disambiguation_notes: { type: "string", description: "What remains uncertain and what the user should verify offline before using the name." },
                  evidence: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        claim: { type: "string" },
                        source_url: { type: "string" },
                        source_type: { type: "string", description: "Examples: wedding registry, public announcement, school/community page, directory snippet, social profile snippet." }
                      },
                      required: %w[claim source_url source_type],
                      additionalProperties: false
                    }
                  }
                },
                required: %w[last_name confidence match_summary disambiguation_notes evidence],
                additionalProperties: false
              }
            },
            rejected_or_ambiguous_matches: {
              type: "array",
              items: { type: "string" },
              description: "Brief notes about tempting but insufficiently supported matches. Avoid sensitive details."
            },
            privacy_notes: {
              type: "array",
              items: { type: "string" },
              description: "PII-minimization notes and omitted information categories."
            }
          },
          required: %w[candidates rejected_or_ambiguous_matches privacy_notes],
          additionalProperties: false
        }
      }
    end
  end

  class CandidateReport
    attr_reader :request, :candidates, :verification_steps, :privacy_notes, :created_at

    def initialize(request:, candidates:, verification_steps:, privacy_notes:)
      @request = request.to_s.strip
      @candidates = Array(candidates).map { |candidate| normalize_hash(candidate) }
      @verification_steps = Array(verification_steps).map(&:to_s).map(&:strip).reject(&:empty?)
      @privacy_notes = Array(privacy_notes).map(&:to_s).map(&:strip).reject(&:empty?)
      @created_at = Time.now.utc
    end

    def violations
      messages = []
      messages << "request is required" if request.empty?
      messages << "at least one candidate or verification step is required" if candidates.empty? && verification_steps.empty?

      candidates.each_with_index do |candidate, index|
        prefix = "candidate #{index + 1}"
        messages << "#{prefix} last_name is required" if candidate["last_name"].to_s.strip.empty?
        messages << "#{prefix} confidence must be high, medium, or low" unless %w[high medium low].include?(candidate["confidence"].to_s)
        messages << "#{prefix} match_summary is required" if candidate["match_summary"].to_s.strip.empty?
        messages << "#{prefix} needs at least one source URL" if Array(candidate["sources"]).empty?
      end

      sensitive_text = JSON.generate(candidates)
      messages << "report must not include emails" if sensitive_text.match?(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)
      messages << "report must not include phone numbers" if sensitive_text.match?(/\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b/)
      messages << "report must not include exact street addresses" if sensitive_text.match?(/\b\d{1,6}\s+[A-Za-z0-9.'-]+\s+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Lane|Ln\.?|Drive|Dr\.?|Court|Ct\.?|Way|Circle|Cir\.?)\b/i)

      messages
    end

    def to_markdown
      <<~MARKDOWN.strip
        # Neighbor Last-Name Recall Research

        Generated: #{created_at.iso8601}

        ## Request
        #{request}

        ## Best Candidates
        #{candidate_markdown}

        ## Verify Before Sending Invitations
        #{numbered_list(verification_steps)}

        ## Privacy Notes
        #{numbered_list(privacy_notes)}
      MARKDOWN
    end

    private
      def normalize_hash(value)
        value.to_h.transform_keys(&:to_s)
      end

      def candidate_markdown
        return "No sufficiently supported candidate was found." if candidates.empty?

        candidates.each_with_index.map do |candidate, index|
          sources = Array(candidate["sources"]).join(", ")
          <<~MARKDOWN.strip
            ### #{index + 1}. #{candidate["last_name"]} — #{candidate["confidence"]} confidence

            - Match: #{candidate["match_summary"]}
            - Caveat: #{candidate["caveat"]}
            - Sources: #{sources.empty? ? "N/A" : sources}
          MARKDOWN
        end.join("\n\n")
      end

      def numbered_list(values)
        values = Array(values).map(&:to_s).map(&:strip).reject(&:empty?)
        return "1. None." if values.empty?

        values.each_with_index.map { |value, index| "#{index + 1}. #{value}" }.join("\n")
      end
  end

  module Tools
    module TaskResultWaiter
      private
        def wait_for_task(run_id)
          deadline = Time.now + Integer(ENV.fetch("PARALLEL_TASK_POLL_SECONDS", "7200"))
          interval = Float(ENV.fetch("PARALLEL_TASK_POLL_INTERVAL", "10"))
          last_status = nil

          parallel_log("task #{run_id} polling started deadline=#{deadline.utc.iso8601} interval=#{interval}s")

          loop do
            status = @parallel_client.task_run_retrieve(run_id: run_id)
            state = status["status"].is_a?(Hash) ? status.dig("status", "status").to_s : status["status"].to_s
            if state != last_status
              parallel_log("task #{run_id} status=#{state}")
              last_status = state
            end

            return @parallel_client.task_run_result(run_id: run_id) if state == "completed"
            raise "Parallel task #{run_id} ended with status #{state}: #{status.inspect}" if %w[failed cancelled canceled].include?(state)
            raise "Parallel task #{run_id} still active after polling timeout" if Time.now >= deadline

            sleep interval
          end
        end

        def parallel_log(message)
          warn "[parallel] #{Time.now.utc.iso8601} #{message}"
        end
    end

    class DeepIdentityResearch < TurnKit::Tool
      include TaskResultWaiter

      tool_name "deep_identity_research"
      description "Run a cited Parallel Task API deep research pass to recover a likely family last name from user-provided first names and locality."
      usage_hint "Use once, before drafting. Use ultra by default. Return only last-name candidates, confidence, non-sensitive evidence, and verification caveats. Never return street addresses, phone numbers, personal emails, DOBs, or unrelated family details."
      parameter :request, :string, required: true, description: "The user's identity-recall request and legitimate purpose."
      parameter :processor, :enum, required: false, enum: %w[base base-fast core core-fast pro pro-fast ultra ultra-fast], default: DEFAULT_DEEP_PROCESSOR, description: "Parallel processor. Use ultra for quality-first deep research unless the user asks for a smoke test."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
        @parallel_client = parallel_client
      end

      def call(request:, processor: DEFAULT_DEEP_PROCESSOR, context:)
        run = @parallel_client.create_task_run(
          input: {
            request: request,
            legitimate_purpose: "The user says they are sending wedding invitations and wants to remember a neighbor family's last name.",
            privacy_constraints: [
              "Use public sources only.",
              "Return only candidate last names and citation URLs needed for user verification.",
              "Do not return exact street addresses, phone numbers, personal emails, dates of birth, or unnecessary details about minors.",
              "Prefer 'not enough evidence' over guessing."
            ],
            task: "Find likely family last-name candidates matching: Billy/William as the husband, wife named Kelly/Kelli/Kelley, Kelly/Kelli/Kelley as a medical professional likely at Bryn Mawr Hospital or Main Line Health, Billy/William as someone who works in sales and has coached hockey, daughter Grace born around a year ago, and Bryn Mawr, PA neighbor context. Use the child detail only for disambiguation; do not return unnecessary minor-specific details. Cite sources and explicitly describe uncertainty."
          },
          task_spec: { output_schema: Schemas.deep_identity_research },
          processor: processor
        )
        parallel_log("deep_identity_research created run_id=#{run.fetch("run_id")} processor=#{processor}")
        wait_for_task(run.fetch("run_id"))
      end
    end

    class WebSearch < TurnKit::Tool
      tool_name "web_search"
      description "Search the web and return source candidates with excerpts."
      usage_hint "Use only for targeted follow-up after deep_identity_research leaves a specific ambiguity."
      parameter :objective, :string, required: true, description: "Natural-language research objective."
      parameter :search_queries, :array, required: true, description: "Two or three targeted keyword queries."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new)
        @parallel_client = parallel_client
      end

      def call(objective:, search_queries:, context:)
        @parallel_client.search(objective: objective, search_queries: search_queries)
      end
    end

    class ReadWebPages < TurnKit::Tool
      MAX_URLS = 6

      tool_name "read_web_pages"
      description "Read multiple public web pages in one call and return relevant extracted content."
      usage_hint "Use for follow-up verification of source URLs. Extract only name-matching evidence; omit sensitive details."
      parameter :urls, :array, required: true, description: "Public URLs to read, up to 6."
      parameter :objective, :string, required: true, description: "What to extract or focus on from the pages."

      def initialize(parallel_client: TurnKitExamples::ParallelClient.new)
        @parallel_client = parallel_client
      end

      def call(urls:, objective:, context:)
        urls = Array(urls).map(&:to_s).uniq
        raise TurnKit::ToolError, "read_web_pages supports at most #{MAX_URLS} URLs" if urls.length > MAX_URLS

        @parallel_client.read_pages(urls: urls, objective: objective)
      end
    end

    class SubmitCandidateReport < TurnKit::Tool
      tool_name "submit_candidate_report"
      description "Submit the final privacy-minimized candidate last-name report."
      usage_hint "Use exactly once after research and self-verification."
      terminal! { |result| result.fetch("markdown") }
      parameter :candidates, :array, required: true, items: {
        type: "object",
        properties: {
          last_name: { type: "string" },
          confidence: { type: "string", enum: %w[high medium low] },
          match_summary: { type: "string" },
          caveat: { type: "string" },
          sources: { type: "array", items: { type: "string" } }
        },
        required: %w[last_name confidence match_summary caveat sources],
        additionalProperties: false
      }, description: "Ranked last-name candidates. Do not include sensitive PII."
      parameter :verification_steps, :array, required: true, description: "Offline steps the user should take before sending invitations."
      parameter :privacy_notes, :array, required: true, description: "Sensitive details intentionally omitted."

      def initialize(request:)
        @request = request
      end

      def call(candidates:, verification_steps:, privacy_notes:, context:)
        report = CandidateReport.new(
          request: @request,
          candidates: candidates,
          verification_steps: verification_steps,
          privacy_notes: privacy_notes
        )
        violations = report.violations
        raise TurnKit::ToolError, "candidate report failed validation: #{violations.join("; ")}" if violations.any?

        { saved: true, markdown: report.to_markdown }
      end
    end
  end

  def self.tools(request:, parallel_client: TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180"))))
    [
      Tools::DeepIdentityResearch.new(parallel_client: parallel_client),
      Tools::WebSearch.new(parallel_client: parallel_client),
      Tools::ReadWebPages.new(parallel_client: parallel_client),
      Tools::SubmitCandidateReport.new(request: request)
    ]
  end
end

TurnKit.configure do |config|
  config.default_model = NeighborNameResearcher::DEFAULT_MODEL
  TurnKitExamples.prepare_model(config.default_model)
  config.store = TurnKit::MemoryStore.new
  config.compaction = {
    context_limit: Integer(ENV.fetch("TURNKIT_CONTEXT_LIMIT", "64000")),
    threshold: 0.75
  }
  config.max_iterations = 15
  config.max_tool_executions = 20
  config.max_tool_executions_by_name = {
    "deep_identity_research" => 1,
    "web_search" => Integer(ENV.fetch("TURNKIT_MAX_WEB_SEARCHES", "2")),
    "read_web_pages" => Integer(ENV.fetch("TURNKIT_MAX_BATCH_PAGE_READS", "2")),
    "submit_candidate_report" => 1
  }
  config.timeout = 600
end

events = []
TurnKit.on_event = ->(event) do
  events << event
  next unless ENV["VERBOSE"] || ENV["DEEP_MONITORING"] || %w[turn.started tool_call.completed turn.completed turn.failed].include?(event.type)

  warn "turnkit.#{event.type} turn=#{event.turn_id} payload=#{event.payload.inspect}"
end

request = ARGV.join(" ").strip
request = NeighborNameResearcher::DEFAULT_REQUEST if request.empty?

privacy_skill = TurnKit::Skill.from_file(File.join(__dir__, "skills", "privacy_minimized_identity_recall.md"))
parallel_client = TurnKitExamples::ParallelClient.new(read_timeout: Integer(ENV.fetch("PARALLEL_READ_TIMEOUT", "180")))

agent = TurnKit::Agent.new(
  name: "neighbor_name_researcher",
  orchestrator: true,
  description: "Uses deep web research to recover a likely neighbor family last name with privacy-minimized output.",
  model: TurnKit.default_model,
  thinking: ({ effort: "none" } if TurnKit.default_model == "gpt-5.6-sol"),
  skills: [privacy_skill],
  tools: NeighborNameResearcher.tools(request: request, parallel_client: parallel_client),
  max_spend: Float(ENV.fetch("TURNKIT_MAX_SPEND", "1.00")),
  max_iterations: Integer(ENV.fetch("TURNKIT_MAX_ITERATIONS", "15")),
  max_tool_executions: Integer(ENV.fetch("TURNKIT_MAX_TOOL_EXECUTIONS", "20")),
  max_tool_executions_by_name: TurnKit.max_tool_executions_by_name,
  compaction: TurnKit.compaction,
  instructions: <<~TEXT
    Help the user remember a neighbor family's last name for wedding invitations.
    This is identity-recall research, not contact-data collection. Research first,
    cite public sources, and then submit exactly one privacy-minimized candidate
    report with submit_candidate_report. Do not reveal street addresses, phone
    numbers, personal emails, birth dates, or unnecessary details about minors.
    If evidence is weak, say so and provide offline verification steps instead
    of guessing.
  TEXT
)

puts "Running neighbor name researcher..."
run = agent.run(
  "Recover likely last-name candidates for the request.",
  input: { request: request }
)

if run.failed?
  warn "Run failed: #{TurnKit.store.load_turn(run.id).fetch("error").inspect}"
  exit 1
end

submitted = run.tool_executions.reverse.find { |execution| execution.tool_name == "submit_candidate_report" }
markdown = submitted&.result.to_h["markdown"]

puts
puts(markdown || run.output_text)
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
    puts "%02d %-22s turn=%s payload=%s" % [index + 1, event.type, event.turn_id, event.payload.inspect]
  end
end
