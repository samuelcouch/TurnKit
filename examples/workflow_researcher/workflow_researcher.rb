# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "net/http"
require "uri"
require "turnkit"

module WorkflowResearcher
  def self.web_tools(parallel_client: ParallelClient.new)
    [
      Tools::WebSearch.new(parallel_client: parallel_client),
      Tools::ReadWebPages.new(parallel_client: parallel_client),
      Tools::ReadWebPage.new(parallel_client: parallel_client)
    ]
  end

  class ParallelClient
    API_BASE = "https://api.parallel.ai"

    def initialize(api_key: ENV["PARALLEL_API_KEY"], api_base: API_BASE, open_timeout: 5, read_timeout: 45)
      @api_key = api_key
      @api_base = api_base
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def search(objective:, search_queries:)
      post("/v1/search", {
        objective: objective,
        search_queries: Array(search_queries)
      })
    end

    def read_page(url:, objective:)
      read_pages(urls: [url], objective: objective)
    end

    def read_pages(urls:, objective:)
      post("/v1/extract", {
        urls: Array(urls),
        objective: objective
      })
    end

    private
      def post(path, payload)
        raise ArgumentError, "PARALLEL_API_KEY is required for web tools" if @api_key.to_s.empty?

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
  end

  module Tools
    class WebSearch < TurnKit::Tool
      tool_name "web_search"
      description "Search the web and return source candidates with excerpts."
      usage_hint "Use when research needs current, source-grounded information or canonical URLs."
      parameter :objective, :string, required: true, description: "Natural-language research objective."
      parameter :search_queries, :array, required: true, description: "Two or three targeted keyword queries."

      def initialize(parallel_client: ParallelClient.new)
        @parallel_client = parallel_client
      end

      def call(objective:, search_queries:, context:)
        @parallel_client.search(objective: objective, search_queries: search_queries)
      end
    end

    class ReadWebPage < TurnKit::Tool
      tool_name "read_web_page"
      description "Read one public web page and return relevant extracted content."
      usage_hint "Use after web_search finds a source, or when the input includes a URL that should be read before answering."
      parameter :url, :string, required: true, description: "Public URL to read."
      parameter :objective, :string, required: true, description: "What to extract or focus on from the page."

      def initialize(parallel_client: ParallelClient.new)
        @parallel_client = parallel_client
      end

      def call(url:, objective:, context:)
        @parallel_client.read_page(url: url, objective: objective)
      end
    end

    class ReadWebPages < TurnKit::Tool
      MAX_URLS = 8

      tool_name "read_web_pages"
      description "Read multiple public web pages in one call and return relevant extracted content."
      usage_hint "Prefer this over repeated read_web_page calls when reading several sources."
      parameter :urls, :array, required: true, description: "Public URLs to read, up to 8."
      parameter :objective, :string, required: true, description: "What to extract or focus on from the pages."

      def initialize(parallel_client: ParallelClient.new)
        @parallel_client = parallel_client
      end

      def call(urls:, objective:, context:)
        urls = Array(urls).map(&:to_s).uniq
        raise TurnKit::ToolError, "read_web_pages supports at most #{MAX_URLS} URLs" if urls.length > MAX_URLS

        @parallel_client.read_pages(urls: urls, objective: objective)
      end
    end
  end
end

TurnKit.configure do |config|
  config.model = ENV.fetch("TURNKIT_MODEL", "gpt-5.2")
  config.store = TurnKit::MemoryStore.new
  config.compaction = {
    context_limit: Integer(ENV.fetch("TURNKIT_CONTEXT_LIMIT", "64000")),
    threshold: 0.75
  }
  config.max_iterations = 20
  config.max_tool_executions = 40
  config.max_tool_executions_by_name = {
    "web_search" => Integer(ENV.fetch("TURNKIT_MAX_WEB_SEARCHES", "3")),
    "read_web_page" => Integer(ENV.fetch("TURNKIT_MAX_PAGE_READS", "8")),
    "read_web_pages" => Integer(ENV.fetch("TURNKIT_MAX_BATCH_PAGE_READS", "2"))
  }
  config.timeout = 300
end

events = []
TurnKit.on_event = ->(event) do
  events << event
  next unless ENV["VERBOSE"] || ENV["DEEP_MONITORING"] || %w[turn.started tool_call.completed turn.completed turn.failed].include?(event.type)

  warn "turnkit.#{event.type} turn=#{event.turn_id} payload=#{event.payload.inspect}"
end

model = TurnKit.model
request = ARGV.join(" ").strip
request = "Create a source-grounded brief on Rails 8 Solid Queue for a Rails founder." if request.empty?

source_grounded_brief = TurnKit::Skill.from_file(File.join(__dir__, "skills", "source_grounded_brief.md"))

workflow = TurnKit::Workflow.new(
  name: "source_brief_orchestrator",
  description: "Creates source-grounded briefs with web research and verification.",
  model: model,
  skills: [source_grounded_brief],
  tools: WorkflowResearcher.web_tools,
  max_spend: Float(ENV.fetch("TURNKIT_MAX_SPEND", "0.50")),
  max_iterations: Integer(ENV.fetch("TURNKIT_MAX_ITERATIONS", "15")),
  max_tool_executions: Integer(ENV.fetch("TURNKIT_MAX_TOOL_EXECUTIONS", "30")),
  max_tool_executions_by_name: TurnKit.max_tool_executions_by_name,
  compaction: TurnKit.compaction,
  instructions: <<~TEXT
    Create source-grounded briefs for the requested audience. Use the loaded
    workflow skill to research, draft, verify, and revise within this single
    conversation. Use web tools for source discovery and page reading. Do not
    invent citations or facts.
  TEXT
)

puts "Running workflow..."
run = workflow.run(
  "Create a source-grounded brief for the request.",
  input: { request: request }
)

if run.failed?
  warn "Run failed: #{TurnKit.store.load_turn(run.id).fetch("error").inspect}"
  exit 1
end

puts
puts run.output
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

  puts
  puts "turn records:"
  run.turn_records.each do |record|
    cost = TurnKit::Cost.from_record(record).total
    usage = TurnKit::Usage.from_h(record["usage"] || {})
    puts "- #{record.fetch("id")} agent=#{record.fetch("agent_name")} status=#{record.fetch("status")} parent=#{record["parent_turn_id"] || "-"} root=#{record.fetch("root_turn_id")} model=#{record["model"]} tokens=#{usage.total_tokens} cost=#{cost || "unknown"}"
  end

  puts
  puts "tool executions:"
  run.turn_records.each do |record|
    TurnKit.store.list_tool_executions(turn_id: record.fetch("id")).each do |execution|
      args = JSON.generate(execution["arguments"] || {})
      args = "#{args[0, 500]}..." if args.length > 500
      error = execution["error"] ? " error=#{execution["error"].inspect}" : ""
      puts "- #{execution.fetch("id")} turn=#{record.fetch("id")} agent=#{record.fetch("agent_name")} tool=#{execution.fetch("tool_name")} status=#{execution.fetch("status")} args=#{args}#{error}"
    end
  end

  puts
  puts "messages:"
  run.turn_records.each do |record|
    conversation = TurnKit.store.load_conversation(record.fetch("conversation_id"))
    messages = TurnKit.store.list_messages(conversation.fetch("id"))
    puts "- turn=#{record.fetch("id")} agent=#{record.fetch("agent_name")} conversation=#{conversation.fetch("id")} messages=#{messages.length}"
    messages.each do |message|
      text = message["text"].to_s.gsub(/\s+/, " ").strip
      text = "#{text[0, 240]}..." if text.length > 240
      puts "  ##{message.fetch("sequence")} #{message.fetch("role")}/#{message.fetch("kind")}: #{text}"
    end
  end
end
