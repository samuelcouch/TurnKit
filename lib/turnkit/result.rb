# frozen_string_literal: true

module TurnKit
  class Result
    attr_reader :parts, :usage, :model, :finish_reason, :output_data

    def initialize(text: "", tool_calls: [], parts: nil, usage: Usage.new, model: nil, finish_reason: nil, output_data: nil)
      @parts = parts ? normalize_parts(parts) : synthesize_parts(text: text, tool_calls: tool_calls)
      @usage = usage || Usage.new
      @model = model
      @finish_reason = finish_reason
      @output_data = output_data
    end

    def text
      parts.filter_map { |part| part["text"] if part["type"] == "text" }.join("\n")
    end

    def tool_calls
      parts.filter_map do |part|
        next unless part["type"] == "tool_call"

        ToolCall.new(id: part.fetch("id"), name: part.fetch("name"), arguments: part["arguments"] || {}, arguments_error: part["arguments_error"])
      end
    end

    def tool_calls?
      tool_calls.any?
    end

    private
      def synthesize_parts(text:, tool_calls:)
        parts = []
        parts << { "type" => "text", "text" => text.to_s } unless text.to_s.empty?
        Array(tool_calls).each do |call|
          parts << { "type" => "tool_call", "id" => call.id, "name" => call.name, "arguments" => call.arguments, "arguments_error" => call.arguments_error }.compact
        end
        parts
      end

      def normalize_parts(value)
        Array(value).map { |part| part.to_h.transform_keys(&:to_s) }
      end
  end
end
