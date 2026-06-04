# frozen_string_literal: true

module TurnKit
  class ToolCall
    attr_reader :id, :name, :arguments

    def initialize(id:, name:, arguments: {})
      @id = id.to_s
      @name = name.to_s
      @arguments = normalize_arguments(arguments)
    end

    private
      def normalize_arguments(value)
        case value
        when Hash
          value.transform_keys(&:to_s)
        when String
          parsed = JSON.parse(value)
          parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end
  end
end
