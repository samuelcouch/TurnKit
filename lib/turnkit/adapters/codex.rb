# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module TurnKit
  module Adapters
    class Codex < Client
      Status = Struct.new(:successful, keyword_init: true) do
        def success? = successful
      end

      attr_reader :command, :sandbox, :working_directory

      def initialize(command: ENV.fetch("CODEX_COMMAND", "codex"), sandbox: "read-only", working_directory: Dir.pwd, runner: nil)
        @command = command.to_s
        @sandbox = sandbox
        @working_directory = working_directory
        @runner = runner || method(:run_command)
      end

      def validate!(model:)
        raise ModelAccessError, "codex command is required" if command.empty?
        raise ModelAccessError, "#{command.inspect} was not found. Install OpenAI Codex CLI and run `codex login --device-auth`." unless executable?(command)

        stdout, stderr, status = @runner.call([ command, "login", "status" ], stdin_data: nil, chdir: working_directory)
        return true if status.success?

        message = [ stderr, stdout ].join("\n").strip
        hint = "Run `#{command} login --device-auth` to connect your ChatGPT/Codex subscription."
        raise ModelAccessError, [ "Codex is not authenticated.", message, hint ].reject(&:empty?).join(" ")
      end

      def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
        raise ToolError, "TurnKit tools are not supported by the Codex adapter; Codex uses its own local tools" if Array(tools).any?

        with_tempfiles(output_schema: output_schema) do |schema_file, output_file|
          command = exec_command(model: model, schema_file: schema_file&.path, output_file: output_file.path)
          stdout, stderr, status = @runner.call(command, stdin_data: prompt_for(messages: messages, instructions: instructions), chdir: working_directory)
          emit_codex_events(stdout, on_event: on_event)
          raise ModelAccessError, stderr.strip.empty? ? "codex exec failed" : stderr.strip unless status.success?

          text = read_output(output_file, stdout)
          Result.new(
            text: text,
            output_data: parse_output_data(text, output_schema: output_schema),
            usage: usage_from_jsonl(stdout),
            model: model
          )
        end
      end

      private
        def exec_command(model:, schema_file:, output_file:)
          args = [ command, "exec", "--json" ]
          args += [ "--sandbox", sandbox.to_s ] if sandbox
          args += [ "--model", model.to_s ] unless model.to_s.empty? || model.to_s == "codex"
          args += [ "--output-schema", schema_file ] if schema_file
          args += [ "-o", output_file, "-" ]
          args
        end

        def prompt_for(messages:, instructions:)
          parts = []
          parts << "System instructions:\n#{instructions}" unless instructions.to_s.empty?
          Array(messages).each do |message|
            attrs = message.respond_to?(:to_h) ? message.to_h : message
            attrs = attrs.transform_keys(&:to_s)
            role = attrs["role"] || "user"
            content = attrs["content"] || attrs["text"] || ""
            parts << "#{role}:\n#{content}"
          end
          parts.join("\n\n")
        end

        def with_tempfiles(output_schema:)
          output_file = Tempfile.new([ "turnkit-codex-output", ".txt" ])
          schema_file = nil
          if output_schema
            schema_file = Tempfile.new([ "turnkit-codex-schema", ".json" ])
            schema_file.write(JSON.generate(output_schema))
            schema_file.flush
          end

          yield schema_file, output_file
        ensure
          schema_file&.close!
          output_file&.close!
        end

        def read_output(output_file, stdout)
          output_file.rewind
          text = output_file.read.to_s
          return text unless text.empty?

          final_message_from_jsonl(stdout) || stdout.to_s
        end

        def final_message_from_jsonl(stdout)
          events = parse_jsonl(stdout)
          messages = events.filter_map do |event|
            item = event["item"]
            next unless item.is_a?(Hash) && item["type"] == "agent_message"

            item["text"]
          end
          messages.last
        end

        def parse_output_data(text, output_schema:)
          return nil unless output_schema

          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end

        def usage_from_jsonl(stdout)
          usage = parse_jsonl(stdout).filter_map { |event| event["usage"] if event.is_a?(Hash) }.last || {}
          input = usage["input_tokens"].to_i
          cached = usage["cached_input_tokens"].to_i
          Usage.new(
            input_tokens: [ input - cached, 0 ].max,
            output_tokens: usage["output_tokens"].to_i,
            cached_tokens: cached,
            thinking_tokens: usage["reasoning_output_tokens"].to_i
          )
        end

        def emit_codex_events(stdout, on_event:)
          return unless on_event

          parse_jsonl(stdout).each do |event|
            on_event.call(type: "codex.#{event.fetch("type", "event")}", payload: event)
          end
        end

        def parse_jsonl(stdout)
          stdout.to_s.each_line.filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end

        def executable?(name)
          return true if @runner != method(:run_command)
          return File.executable?(name) if name.include?(File::SEPARATOR)

          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |path| File.executable?(File.join(path, name)) }
        end

        def run_command(command, stdin_data:, chdir:)
          stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin_data, chdir: chdir)
          [ stdout, stderr, status ]
        end
    end
  end
end
