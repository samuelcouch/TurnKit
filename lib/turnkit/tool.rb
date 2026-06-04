# frozen_string_literal: true

module TurnKit
  class Tool
    TYPES = %i[string integer number boolean array object enum].freeze

    class << self
      def tool_name(value = nil)
        @tool_name = value.to_s if value
        @tool_name ||= name.to_s.split("::").last.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end

      def description(value = nil)
        @description = value.to_s if value
        @description.to_s
      end

      def parameter(name, type = :string, required: false, description: "", default: nil, enum: nil)
        raise ArgumentError, "unknown parameter type: #{type}" unless TYPES.include?(type)

        parameters << {
          name: name.to_s,
          type: type,
          required: required ? true : false,
          description: description.to_s,
          default: default,
          enum: enum
        }.compact
      end

      def parameters
        @parameters ||= superclass.respond_to?(:parameters) ? superclass.parameters.dup : []
      end

      def ends_turn?
        false
      end

      def completion_message(_result)
        nil
      end

      def call(arguments = {}, context:)
        keyword_arguments = symbolize(arguments)
        instance = new
        if accepts_turnkit_context?(instance)
          instance.call(**keyword_arguments, turnkit_context: context)
        else
          instance.call(**keyword_arguments, context: context)
        end
      end

      private
        def accepts_turnkit_context?(instance)
          instance.method(:call).parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :turnkit_context }
        end

        def symbolize(hash)
          hash.transform_keys(&:to_sym)
        end
    end
  end
end
