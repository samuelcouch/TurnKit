# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "pathname"
require "turnkit"

# Model routing after Spotify's "shunt" plugin: a cheap worker model reads bulk
# files or writes boilerplate, and the primary model receives only the answer.
# Three layers degrade gracefully: a tool policy blocks expensive reads and
# names the alternative, typed tools do the I/O, and a short skill says when.
module Shunt
  READ_LINES = Integer(ENV.fetch("SHUNT_MIN_LINES", 350))
  SKILL = TurnKit::Skill.from_file(File.join(__dir__, "skills", "bulk-reader.md"))

  module Confined
    def initialize(root:)
      @root = Pathname(root).expand_path
    end

    def resolve(path)
      target = @root.join(path).expand_path
      raise TurnKit::ToolError, "#{path} is outside the project root" unless target.to_s.start_with?("#{@root}/")
      target
    end

    def read(path)
      target = resolve(path)
      raise TurnKit::ToolError, "#{path} is not a file" unless target.file?
      target.read
    end
  end

  class ReadFile < TurnKit::Tool
    include Confined
    tool_name "read_file"
    description "Read a text file, or one section of it with offset and limit (1-based lines)."
    parameter :path, :string, required: true
    parameter :offset, :integer
    parameter :limit, :integer

    def call(path:, offset: 1, limit: nil, context:)
      lines = read(path).lines
      { "path" => path, "content" => lines[offset - 1, limit || lines.length].join }
    end
  end

  class WriteFile < TurnKit::Tool
    include Confined
    tool_name "write_file"
    description "Write the complete generated file to disk."
    parameter :path, :string, required: true
    parameter :content, :string, required: true
    terminal! { |result| "Wrote #{result.fetch('path')} (#{result.fetch('bytes')} bytes)." }

    def call(path:, content:, context:)
      target = resolve(path)
      target.dirname.mkpath
      { "path" => path, "bytes" => target.write(content) }
    end
  end

  # The worker is an ordinary agent; the tool assembles its task in Ruby, so the
  # file contents go to the worker and never enter the primary model's context.
  class Worker < TurnKit::SubAgentTool
    include Confined
    attr_reader :agent

    def initialize(agent:, root:)
      @agent = agent
      super(root: root)
    end
  end

  class BulkRead < Worker
    tool_name "bulk_read"
    description "Answer a question about large or many files without reading them yourself; only the answer enters your context."
    usage_hint "Use for files over #{READ_LINES} lines or questions spanning 3+ files. Not for debugging or line-precise edits."
    parameter :question, :string, required: true
    parameter :paths, :array, required: true, items: :string

    def task_for(question:, paths:)
      files = paths.map { |path| "<file path=\"#{path}\">\n#{read(path)}\n</file>" }
      "#{question}\n\n#{files.join("\n\n")}"
    end
  end

  class CodeWrite < Worker
    tool_name "code_write"
    description "Generate a predictable file (tests, config, stubs) from a spec and a reference file. The code is written to disk and never enters your context."
    usage_hint "Use when most of the output follows the reference's patterns. Review the written file with a targeted read afterwards."
    parameter :spec, :string, required: true, description: "What the file must contain."
    parameter :reference, :string, required: true, description: "Existing file whose patterns the output must match."
    parameter :target, :string, required: true, description: "Path to write."

    def task_for(spec:, reference:, target:)
      "Write #{target}.\n\nSpec:\n#{spec}\n\n<reference path=\"#{reference}\">\n#{read(reference)}\n</reference>"
    end
  end

  # Hard gate: full reads of large files are blocked with a redirect. Targeted
  # reads pass because editing needs exact lines the worker cannot supply.
  def self.read_gate(root)
    lambda do |tool:, arguments:, **|
      next :allow unless tool.tool_name == "read_file" && !arguments["offset"] && !arguments["limit"]
      file = Pathname(root).join(arguments["path"].to_s)
      next :allow unless file.file? && (lines = file.each_line.count) > READ_LINES
      [ :block, "#{arguments['path']} is #{lines} lines (limit #{READ_LINES}). Use bulk_read to understand it; " \
        "re-read with offset/limit for the exact section you will edit." ]
    end
  end

  def self.agent(root:, model:, worker_model:, client: nil)
    root = Pathname(root).expand_path
    bulk_reader = TurnKit::Agent.new(name: "bulk_reader", model: worker_model, client: client, inherit_globals: false,
      instructions: "You are a precise code analyst. Read the provided files and answer the question concisely. " \
        "Output structured bullets only. No greetings, no prose, no preambles. Lead every bullet with the exact " \
        "name, type, or line number. Skip anything the caller did not ask for.")
    code_writer = TurnKit::Agent.new(name: "code_writer", model: worker_model, client: client, inherit_globals: false,
      tools: [ WriteFile.new(root: root) ],
      instructions: "You generate one code file from a spec and a reference file. Match the reference's patterns, " \
        "conventions, naming and style exactly. Call write_file once with the complete file; never answer with code as text.")
    TurnKit::Agent.new(name: "shunt", model: model, client: client, orchestrator: true, inherit_globals: false,
      instructions: "Answer questions about, and extend, the code under the project root. Paths are relative to it.",
      skills: [ SKILL ],
      tools: [ ReadFile.new(root: root), BulkRead.new(agent: bulk_reader, root: root), CodeWrite.new(agent: code_writer, root: root) ],
      tool_policy: read_gate(root))
  end

  # Estimated primary-context tokens (chars / 4) that delegation kept out of the
  # parent: bytes sent to workers versus the answers that came back.
  class Savings
    attr_reader :delegated, :returned

    def initialize
      @delegated, @returned = {}, {}
    end

    def call(event)
      case event.type
      when "sub_agent.delegated" then @delegated[event.payload[:id]] = event.payload[:task_chars]
      when "tool_call.completed" then @returned[event.payload[:id]] = event.payload[:result_chars] if @delegated.key?(event.payload[:id])
      end
    end

    def to_h
      sent, back = delegated.values.sum, returned.values.sum
      { "delegations" => delegated.length, "delegated_tokens" => sent / 4, "returned_tokens" => back / 4,
        "saved" => sent.zero? ? nil : format("%.0f%%", 100.0 * (sent - back) / sent) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative "../shared/model_registry"
  RubyLLM.configure { |config| config.logger = Logger.new($stderr, level: Logger::WARN) }
  model, worker_model = ENV.fetch("TURNKIT_MODEL", "claude-sonnet-5"), ENV.fetch("SHUNT_WORKER_MODEL", "gemini-2.5-flash")
  [ model, worker_model ].each { |name| TurnKitExamples.prepare_model(name) }
  TurnKit.max_spend = Float(ENV.fetch("TURNKIT_MAX_SPEND", "1.0"))
  savings = Shunt::Savings.new
  agent = Shunt.agent(root: ENV.fetch("SHUNT_ROOT", Dir.pwd), model: model, worker_model: worker_model)
  run = agent.run(ARGV.join(" "), async: true)
  run.run! { |event| savings.call(event) }
  raise "Run failed: #{run.error.inspect}" unless run.completed?
  puts run.output_text
  warn JSON.generate(savings.to_h.merge("tools" => run.tool_executions.map(&:tool_name), "tokens" => run.usage.total_tokens, "cost" => run.cost.total))
end
