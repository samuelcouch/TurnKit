# frozen_string_literal: true

module TurnKit
  class Tool
    TYPES = %i[string integer number boolean array object enum].freeze
    NAME_PATTERN = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    class << self
      def tool_name(value = nil)
        @tool_name = value.to_s if value
        @tool_name ||= name.to_s.split("::").last.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end

      def description(value = nil)
        @description = value.to_s if value
        @description.to_s
      end

      def usage_hint(value = nil)
        @usage_hint = value.to_s if value
        @usage_hint.to_s
      end

      def parameter(name, type = :string, required: false, description: "", default: nil, enum: nil, items: nil, properties: nil)
        name = name.to_s
        raise ArgumentError, "unknown parameter type: #{type}" unless TYPES.include?(type)
        raise ArgumentError, "invalid parameter name: #{name}" unless NAME_PATTERN.match?(name)
        raise ArgumentError, "duplicate parameter: #{name}" if parameters.any? { |param| param.fetch(:name) == name }
        raise ArgumentError, "enum values are required for enum parameter: #{name}" if type == :enum && Array(enum).empty?

        parameters << {
          name: name,
          type: type,
          required: required ? true : false,
          description: description.to_s,
          default: default,
          enum: enum,
          items: items,
          properties: properties
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

      def validate_definition!
        raise ArgumentError, "tool name is required" if tool_name.empty?
        raise ArgumentError, "invalid tool name: #{tool_name}" unless NAME_PATTERN.match?(tool_name)

        parameters.each do |param|
          type = param.fetch(:type)
          raise ArgumentError, "unknown parameter type: #{type}" unless TYPES.include?(type)
          raise ArgumentError, "enum values are required for enum parameter: #{param.fetch(:name)}" if type == :enum && Array(param[:enum]).empty?
          validate_value!(param[:default], param) if param.key?(:default)
        end
        true
      end

      def input_schema
        properties = parameters.to_h { |param| [ param.fetch(:name), schema_for(param) ] }
        required = parameters.select { |param| param.fetch(:required) }.map { |param| param.fetch(:name) }
        {
          "type" => "object",
          "properties" => properties,
          "required" => required
        }
      end

      def validate_arguments(arguments)
        attrs = arguments.respond_to?(:to_h) ? arguments.to_h.transform_keys(&:to_s) : {}
        allowed = parameters.map { |param| param.fetch(:name) }
        unknown = attrs.keys - allowed
        raise ToolValidationError, "unknown argument#{unknown.length == 1 ? "" : "s"}: #{unknown.join(", ")}" if unknown.any?

        normalized = {}
        parameters.each do |param|
          name = param.fetch(:name)
          if attrs.key?(name)
            value = attrs[name]
          elsif param.key?(:default)
            value = param[:default]
          elsif param.fetch(:required)
            raise ToolValidationError, "missing required argument: #{name}"
          else
            next
          end

          validate_value!(value, param)
          normalized[name] = value
        end
        normalized
      end

      def call(arguments = {}, context:)
        keyword_arguments = symbolize(validate_arguments(arguments))
        instance = new
        if accepts_turnkit_context?(instance)
          instance.call(**keyword_arguments, turnkit_context: context)
        else
          instance.call(**keyword_arguments, context: context)
        end
      end

      private
        def schema_for(param)
          schema = {
            "type" => schema_type(param.fetch(:type)),
            "description" => param[:description].to_s
          }.reject { |_key, value| value.nil? || value == "" }
          schema["enum"] = Array(param[:enum]) if param[:enum]
          schema["default"] = param[:default] if param.key?(:default)
          schema["items"] = normalize_items(param[:items]) if param[:items]
          schema["properties"] = normalize_properties(param[:properties]) if param[:properties]
          schema
        end

        def schema_type(type)
          type == :enum ? "string" : type.to_s
        end

        def normalize_items(value)
          return { "type" => value.to_s } if value.is_a?(Symbol)

          stringify_schema(value)
        end

        def normalize_properties(value)
          value.to_h.transform_keys(&:to_s).transform_values { |schema| stringify_schema(schema) }
        end

        def stringify_schema(value)
          case value
          when Hash
            value.transform_keys(&:to_s).transform_values { |nested| nested.is_a?(Hash) ? stringify_schema(nested) : nested }
          else
            { "type" => value.to_s }
          end
        end

        def validate_value!(value, param)
          return if value.nil? && !param.fetch(:required)

          case param.fetch(:type)
          when :string, :enum
            raise ToolValidationError, "#{param.fetch(:name)} must be a string" unless value.is_a?(String)
          when :integer
            raise ToolValidationError, "#{param.fetch(:name)} must be an integer" unless value.is_a?(Integer)
          when :number
            raise ToolValidationError, "#{param.fetch(:name)} must be a number" unless value.is_a?(Numeric)
          when :boolean
            raise ToolValidationError, "#{param.fetch(:name)} must be a boolean" unless value == true || value == false
          when :array
            raise ToolValidationError, "#{param.fetch(:name)} must be an array" unless value.is_a?(Array)
          when :object
            raise ToolValidationError, "#{param.fetch(:name)} must be an object" unless value.is_a?(Hash)
          end

          if param[:enum] && !Array(param[:enum]).include?(value)
            raise ToolValidationError, "#{param.fetch(:name)} must be one of: #{Array(param[:enum]).join(", ")}"
          end
        end

        def accepts_turnkit_context?(instance)
          instance.method(:call).parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :turnkit_context }
        end

        def symbolize(hash)
          hash.transform_keys(&:to_sym)
        end
    end
  end
end
