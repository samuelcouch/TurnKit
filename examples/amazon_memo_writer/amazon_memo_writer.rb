# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "benchmark"
require "json"
require "turnkit"

module AmazonMemoWriter
  DEFAULT_MODEL = ENV.fetch("TURNKIT_MODEL", "gpt-5")
  DEFAULT_TASK = "Write a memo recommending whether TurnKit should create an enterprise onboarding support lane. Audience: founder and product lead. Decision deadline: this week."

  SOURCES = {
    "https://example.com/customer-support-latency" => {
      title: "Support Latency Benchmark",
      excerpt: "Enterprise customers abandon onboarding when first-response time exceeds 24 hours. Median B2B support response is 18 hours. Teams that add onboarding-specific routing reduce time-to-first-response by 35%."
    },
    "https://example.com/amazon-prfaq" => {
      title: "Working Backwards PR/FAQ Notes",
      excerpt: "Amazon-style decision memos explain the customer problem, make one explicit recommendation, use narrative paragraphs instead of tables, and include risks plus open questions."
    },
    "https://example.com/onboarding-economics" => {
      title: "Onboarding Economics Study",
      excerpt: "For enterprise software, implementation delays in the first 30 days are correlated with lower expansion intent. Customers cite unclear ownership and slow responses as top causes."
    }
  }.freeze

  class AmazonMemo
    EM_DASH = "—"
    MAX_PARAGRAPH_WORDS = 45

    FIELDS = %i[
      title author date tldr customer_problem current_evidence recommendation
      risks_and_open_questions next_steps sources
    ].freeze
    PARAGRAPH_FIELDS = %i[tldr customer_problem current_evidence recommendation].freeze
    LIST_FIELDS = %i[risks_and_open_questions next_steps].freeze
    PARAGRAPH_SECTIONS = {
      "TL;DR" => :tldr,
      "Customer Problem" => :customer_problem,
      "Current Evidence" => :current_evidence,
      "Recommendation" => :recommendation
    }.freeze
    LIST_SECTIONS = [
      "Risks and Open Questions",
      "Next Steps",
      "Sources"
    ].freeze

    attr_reader(*FIELDS)

    def initialize(**attributes)
      FIELDS.each do |field|
        value = attributes.fetch(field)
        value = normalize_sources(value) if field == :sources
        value = normalize_string_array(value) if LIST_FIELDS.include?(field)
        instance_variable_set("@#{field}", value)
      end
    end

    def violations(read_urls:)
      messages = []
      FIELDS.each do |field|
        messages << "#{field} is required" if blank_value?(public_send(field))
      end
      messages << "title must be plain text; the renderer adds the Markdown heading" if title.to_s.start_with?("#")
      messages << "TL;DR must be 35 words or fewer" if tldr.to_s.split.length > 35
      messages << "risks_and_open_questions must include at least one ranked item" if risks_and_open_questions.empty?
      messages << "next_steps must include at least one ranked item" if next_steps.empty?
      messages << "sources must include at least two read source URLs" if sources.length < 2

      %i[title author date].each do |field|
        messages << "#{field} must not contain em dashes" if public_send(field).to_s.include?(EM_DASH)
      end

      unknown_sources = sources - read_urls
      messages << "sources must come from read_web_page results: #{unknown_sources.join(", ")}" if unknown_sources.any?

      PARAGRAPH_FIELDS.each do |field|
        value = public_send(field).to_s
        messages << "#{field} must not contain em dashes" if value.include?(EM_DASH)
        messages << "#{field} must not contain Markdown tables" if value.include?("|")
        messages << "#{field} must not include Markdown headings; submit field text only" if value.match?(/^#/)
        paragraph_blocks(value).each_with_index do |paragraph, index|
          messages << "#{field} paragraph #{index + 1} must be #{MAX_PARAGRAPH_WORDS} words or fewer" if paragraph.split.length > MAX_PARAGRAPH_WORDS
        end
      end

      LIST_FIELDS.each do |field|
        public_send(field).each_with_index do |item, index|
          text = item.to_s.strip
          messages << "#{field} item #{index + 1} is required" if text.empty?
          messages << "#{field} item #{index + 1} must not contain em dashes" if text.include?(EM_DASH)
          messages << "#{field} item #{index + 1} must not contain Markdown tables" if text.include?("|")
          messages << "#{field} item #{index + 1} must not include Markdown headings" if text.match?(/^#/)
          messages << "#{field} item #{index + 1} must be 35 words or fewer" if text.split.length > 35
        end
      end

      unless recommendation.to_s.match?(/\A(Create|Build|Launch|Start|Adopt|Defer|Do not|Pilot|Implement|Recommend)\b/i)
        messages << "recommendation must start with a clear action verb"
      end

      messages
    end

    def to_markdown
      <<~MARKDOWN.strip
        # #{title}
        Author: #{author}
        Date: #{date}
        Status: Draft

        ## TL;DR
        #{tldr}

        ## Customer Problem
        #{customer_problem}

        ## Current Evidence
        #{current_evidence}

        ## Recommendation
        #{recommendation}

        ## Risks and Open Questions
        #{numbered_list(risks_and_open_questions)}

        ## Next Steps
        #{numbered_list(next_steps)}

        ## Sources
        #{numbered_list(sources)}
      MARKDOWN
    end

    def self.rendered_violations(output, expected_sources: SOURCES.keys)
      violations = []
      required = [
        "# ",
        "Author:",
        "Date:",
        "Status: Draft",
        "## TL;DR",
        "## Customer Problem",
        "## Current Evidence",
        "## Recommendation",
        "## Risks and Open Questions",
        "## Next Steps",
        "## Sources"
      ]

      cursor = -1
      required.each do |marker|
        index = output.index(marker)
        violations << violation("missing_section", "missing #{marker}") unless index
        violations << violation("section_order", "#{marker} appears out of order") if index && index < cursor
        cursor = index if index
      end

      violations << violation("tables_forbidden", "memo uses a Markdown table") if output.include?("|")
      violations << violation("em_dash_forbidden", "memo contains an em dash") if output.include?(EM_DASH)

      unordered_lines = output.lines.each_with_index.filter_map { |line, index| index + 1 if line.match?(/^\s*[-*]\s+/) }
      if unordered_lines.any?
        violations << violation("numbered_lists_only", "memo contains unordered list markers on lines #{unordered_lines.join(", ")}")
      end

      required.select { |marker| marker.start_with?("##") }.each do |marker|
        violations << violation("missing_whitespace", "#{marker} should be separated by a blank line") unless output.include?("\n\n#{marker}")
      end

      PARAGRAPH_SECTIONS.each_key do |heading|
        paragraph_section_violations(output, heading).each { |message| violations << message }
      end

      LIST_SECTIONS.each do |heading|
        numbered_section_violations(output, heading).each { |message| violations << message }
      end

      cited_sources = expected_sources.select { |url| output.include?(url) }
      if cited_sources.length < 2
        violations << violation("insufficient_sources", "expected at least two cited read sources, got #{cited_sources.length}")
      end

      tldr = output[/## TL;DR\s*\n(.+?)\n\n/m, 1].to_s.strip
      violations << violation("tldr_missing", "TL;DR body missing") if tldr.empty?
      violations << violation("tldr_too_long", "TL;DR has #{tldr.split.length} words; expected 35 or fewer") if tldr.split.length > 35

      recommendation = output[/## Recommendation\s*\n(.+?)(?:\n\n##|\z)/m, 1].to_s.strip
      violations << violation("recommendation_missing", "recommendation body missing") if recommendation.empty?
      unless recommendation.match?(/\A(Create|Build|Launch|Start|Adopt|Defer|Do not|Pilot|Implement|Recommend)\b/i)
        violations << violation("no_clear_recommendation", "recommendation should start with a clear action verb")
      end

      violations
    end

    def self.section_body(output, heading)
      output[/## #{Regexp.escape(heading)}\s*\n(.+?)(?:\n\n##|\z)/m, 1].to_s.strip
    end

    def self.paragraph_section_violations(output, heading)
      section = section_body(output, heading)
      return [ violation("paragraph_missing", "#{heading} body missing") ] if section.empty?

      paragraph_blocks(section).each_with_index.filter_map do |paragraph, index|
        next unless paragraph.split.length > MAX_PARAGRAPH_WORDS

        violation("short_paragraphs", "#{heading} paragraph #{index + 1} has #{paragraph.split.length} words; expected #{MAX_PARAGRAPH_WORDS} or fewer")
      end
    end

    def self.numbered_section_violations(output, heading)
      section = section_body(output, heading)
      return [ violation("numbered_list_missing", "#{heading} list missing") ] if section.empty?

      lines = section.lines.map(&:strip).reject(&:empty?)
      lines.each_with_index.filter_map do |line, index|
        next if line.match?(/\A#{index + 1}\.\s+\S/)

        violation("numbered_lists_only", "#{heading} line #{index + 1} should start with #{index + 1}. ")
      end
    end

    def self.violation(rule, message)
      { rule: rule, message: message }
    end

    def self.paragraph_blocks(value)
      value.to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?)
    end

    private
      def blank_value?(value)
        return value.strip.empty? if value.is_a?(String)
        return value.empty? if value.respond_to?(:empty?)

        value.to_s.strip.empty?
      end

      def paragraph_blocks(value)
        self.class.paragraph_blocks(value)
      end

      def normalize_string_array(value)
        Array(value).map { |item| item.to_s.strip }.reject(&:empty?)
      end

      def normalize_sources(value)
        Array(value).map do |source|
          if source.respond_to?(:to_h)
            attrs = source.to_h.transform_keys(&:to_s)
            attrs["url"] || attrs["source_url"] || source.to_s
          else
            source.to_s
          end
        end.uniq
      end

      def numbered_list(items)
        items.each_with_index.map { |item, index| "#{index + 1}. #{item}" }.join("\n")
      end
  end

  module Tools
    class WebSearch < TurnKit::Tool
      tool_name "web_search"
      description "Search the web for source candidates with excerpts."
      usage_hint "Use before writing claims that need external evidence."
      parameter :objective, :string, required: true, description: "Research objective."
      parameter :search_queries, :array, required: true, description: "Two or three targeted search queries."

      def call(objective:, search_queries:, context:)
        {
          objective: objective,
          search_queries: search_queries,
          results: SOURCES.map { |url, attrs| attrs.merge(url: url) }
        }
      end
    end

    class ReadWebPage < TurnKit::Tool
      tool_name "read_web_page"
      description "Read one public web page and return relevant extracted evidence."
      usage_hint "Use after web_search before citing a URL."
      parameter :url, :string, required: true, description: "URL returned by web_search."
      parameter :objective, :string, required: true, description: "What to extract from the page."

      def call(url:, objective:, context:)
        attrs = SOURCES.fetch(url)
        attrs.merge(url: url, objective: objective)
      end
    end

    class SubmitAmazonMemo < TurnKit::Tool
      tool_name "submit_amazon_memo"
      description "Submit the final Amazon-style memo as structured fields. Validates fields and renders exact Markdown."
      usage_hint "Use only after web_search and read_web_page. This is the only valid way to finalize the memo."
      parameter :title, :string, required: true, description: "Plain-text title. Do not include Markdown heading syntax."
      parameter :author, :string, required: true, description: "Memo author."
      parameter :date, :string, required: true, description: "Memo date."
      parameter :tldr, :string, required: true, description: "TL;DR, 35 words or fewer."
      parameter :customer_problem, :string, required: true, description: "Customer problem paragraph, 45 words or fewer."
      parameter :current_evidence, :string, required: true, description: "Evidence paragraph grounded in read sources, 45 words or fewer."
      parameter :recommendation, :string, required: true, description: "One clear action recommendation, starting with an action verb, 45 words or fewer."
      parameter :risks_and_open_questions, :array, required: true, items: :string, description: "Ranked risks and open questions, most important first. The renderer turns this into a numbered list."
      parameter :next_steps, :array, required: true, items: :string, description: "Ranked final next steps, most important first. The renderer turns this into a numbered list."
      parameter :sources, :array, required: true, items: :string, description: "Array of read source URLs used in the memo, strongest evidence first. The renderer turns this into a numbered list."
      terminal! { |result| result.fetch("memo") }

      def call(title:, author:, date:, tldr:, customer_problem:, current_evidence:, recommendation:, risks_and_open_questions:, next_steps:, sources:, context:)
        memo = AmazonMemo.new(
          title: title,
          author: author,
          date: date,
          tldr: tldr,
          customer_problem: customer_problem,
          current_evidence: current_evidence,
          recommendation: recommendation,
          risks_and_open_questions: risks_and_open_questions,
          next_steps: next_steps,
          sources: sources
        )
        violations = memo.violations(read_urls: read_urls(context.turn))
        raise TurnKit::ToolError, violations.join("; ") if violations.any?

        { memo: memo.to_markdown, sources: memo.sources }
      end

      private
        def read_urls(turn)
          turn.tool_executions.filter_map do |execution|
            next unless execution.completed? && execution.tool_name == "read_web_page"

            execution.result["url"] || execution.result[:url]
          end
        end
    end
  end

  def self.format_policy(output)
    AmazonMemo.rendered_violations(output)
  end

  def self.semantic_policy(model: DEFAULT_MODEL, thinking: { effort: :medium })
    TurnKit::OutputPolicy.new(
      model: model,
      thinking: thinking,
      content: <<~POLICY
        This benchmark uses deterministic read_web_page fixture URLs under example.com.
        Treat these URLs as the source evidence returned by the tools; do not reject
        the memo merely because the fixture domain is example.com.

        The required benchmark skeleton is title, metadata, TL;DR, Customer Problem,
        Current Evidence, Recommendation, Risks and Open Questions, Next Steps, and
        Sources. Treat this skeleton as the source of truth even if generic memo
        guidance would normally put customer problem first or end on risks.

        Read page evidence available to the memo:
        #{SOURCES.map.with_index { |(url, attrs), index| "#{index + 1}. #{url}: #{attrs.fetch(:excerpt)}" }.join("\n")}

        Approve only if the output is an Amazon-style decision memo that:
        1. is source-grounded in the read page evidence,
        2. makes exactly one clear recommendation,
        3. explains customer problem, evidence, risks, open questions, and next steps,
        4. uses numbered lists only, ordered most important to least important,
        5. contains no em dashes,
        6. uses short paragraphs and clear whitespace,
        7. follows the requested memo format without adding unrelated commentary.
      POLICY
    )
  end

  def self.workflow(model: DEFAULT_MODEL, thinking: { effort: :medium }, client: TurnKit::Adapters::RubyLLM.new, on_event: nil, semantic_audit: true)
    policies = [ ->(output) { format_policy(output) } ]
    policies << semantic_policy(model: model, thinking: thinking) if semantic_audit

    TurnKit::Workflow.new(
      name: "amazon_memo_writer",
      description: "Creates source-grounded Amazon-style memos.",
      model: model,
      thinking: thinking,
      client: client,
      tools: [ Tools::WebSearch, Tools::ReadWebPage, Tools::SubmitAmazonMemo ],
      skills: [ workflow_skill ],
      max_iterations: 8,
      max_tool_executions: 8,
      max_tool_executions_by_name: { web_search: 1, read_web_page: 3 },
      max_spend: Float(ENV.fetch("TURNKIT_MAX_SPEND", "1.00")),
      output_policy: policies,
      output_policy_mode: ENV.fetch("TURNKIT_OUTPUT_POLICY_MODE", "report").to_sym,
      on_event: on_event,
      instructions: <<~TEXT
        Write an Amazon-style memo excerpt for a product decision.

        You must use tools before final output:
        1. call web_search once to find source candidates;
        2. call read_web_page for at least two sources;
        3. cite only URLs that were read with read_web_page;
        4. call submit_amazon_memo to finalize. Do not write the final memo directly.

        Before calling submit_amazon_memo, edit the memo fields so paragraphs are short, lists are ranked most important to least important, and no field contains an em dash.

        The submit_amazon_memo tool validates and renders exact Markdown. Submit plain field text only; the renderer adds headings, Status: Draft, numbered lists, and whitespace.
      TEXT
    )
  end

  def self.workflow_skill
    TurnKit::Skill.new(
      key: "amazon_style_memo",
      name: "Amazon Style Memo",
      description: "Research, draft, and edit strict Amazon-style memos.",
      content: <<~TEXT
        Workflow:
        1. Use web_search first to find source candidates.
        2. Use read_web_page for at least two sources before citing them.
        3. Draft from evidence only.
        4. Edit paragraphs down to short blocks with clear whitespace.
        5. Rank every list from most important to least important.
        6. Remove every em dash.
        7. Finalize by calling submit_amazon_memo with structured fields. Do not output free-form final Markdown yourself.
      TEXT
    )
  end

  def self.accuracy(output, run)
    checks = {
      searched_once: run.tool_calls.count { |tool| tool.tool_name == "web_search" && tool.completed? } == 1,
      read_at_least_two_pages: run.tool_calls.count { |tool| tool.tool_name == "read_web_page" && tool.completed? } >= 2,
      finalized_with_submit_tool: run.tool_calls.any? { |tool| tool.tool_name == "submit_amazon_memo" && tool.completed? },
      strict_format_clean: format_policy(output).empty?,
      cites_read_sources: SOURCES.keys.count { |url| output.include?(url) } >= 2,
      audit_clean: run.output_audit_clean?
    }
    passed = checks.values.count(true)
    {
      score: (passed * 100.0 / checks.length).round(1),
      passed: passed,
      total: checks.length,
      checks: checks,
      format_violations: format_policy(output)
    }
  end

  def self.benchmark(task: DEFAULT_TASK, model: DEFAULT_MODEL, thinking: { effort: ENV.fetch("TURNKIT_THINKING_EFFORT", "medium").to_sym }, semantic_audit: true)
    TurnKit.store = TurnKit::MemoryStore.new
    TurnKit.default_model = model
    TurnKit.client = TurnKit::Adapters::RubyLLM.new
    TurnKit.compaction = false
    TurnKit.timeout = 600
    TurnKit.output_policy_model = model
    TurnKit.output_policy_thinking = thinking
    TurnKit.cost_rates[model] ||= { input: 1.25, output: 10.0, cached_input: 0.125, thinking: 10.0 }

    events = []
    run = nil
    elapsed = Benchmark.realtime do
      run = workflow(model: model, thinking: thinking, on_event: ->(event) { events << event }, semantic_audit: semantic_audit).run(task)
    end

    {
      model: model,
      thinking: thinking,
      elapsed_seconds: elapsed.round(2),
      status: run.status,
      output_audit_clean: run.output_audit_clean?,
      output_audit: run.output_audit,
      model_calls: events.count { |event| event.type.end_with?("model.completed") },
      model_call_types: events.select { |event| event.type.end_with?("model.completed") }.map(&:type),
      tool_calls: run.tool_calls.map { |tool| { name: tool.tool_name, status: tool.status, error: tool.error } }.map { |attrs| attrs.compact },
      usage: run.usage.to_h,
      cost: run.cost.to_h,
      accuracy: accuracy(run.output, run),
      event_types: events.map(&:type).uniq,
      output: run.output
    }
  end
end

if $PROGRAM_NAME == __FILE__
  result = AmazonMemoWriter.benchmark(task: ARGV.join(" ").strip.empty? ? AmazonMemoWriter::DEFAULT_TASK : ARGV.join(" "))
  output = result.delete(:output)
  puts "--- BENCHMARK ---"
  puts JSON.pretty_generate(result)
  puts "\n--- OUTPUT ---"
  puts output
end
