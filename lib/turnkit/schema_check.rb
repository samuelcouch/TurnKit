# frozen_string_literal: true

module TurnKit
  module SchemaCheck
    module_function

    def validate!(value, schema, error_class: ToolValidationError, label: "input")
      schema = stringify_schema(schema || {})
      type = schema["type"] || "object"
      validate_type!(value, type, schema, error_class: error_class, label: label)
      validate_enum!(value, schema, error_class: error_class, label: label)

      if type == "object" && schema["properties"]
        attrs = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_s) : {}
        required = Array(schema["required"]).map(&:to_s)
        missing = required.reject { |name| attrs.key?(name) }
        raise error_class, "#{label} missing required field#{missing.length == 1 ? "" : "s"}: #{missing.join(", ")}" if missing.any?

        schema.fetch("properties", {}).each do |name, child_schema|
          next unless attrs.key?(name)

          validate!(attrs[name], child_schema, error_class: error_class, label: "#{label}.#{name}")
        end
      elsif type == "array" && schema["items"] && value.is_a?(Array)
        value.each_with_index do |item, index|
          validate!(item, schema["items"], error_class: error_class, label: "#{label}[#{index}]")
        end
      end

      true
    end

    def stringify_schema(value)
      case value
      when Hash
        value.transform_keys(&:to_s).transform_values { |nested| stringify_schema(nested) }
      when Array
        value.map { |nested| stringify_schema(nested) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def validate_type!(value, type, schema, error_class:, label:)
      return if value.nil? && !Array(schema["required"]).include?(label.to_s)

      valid = case type.to_s
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "array" then value.is_a?(Array)
      when "object" then value.is_a?(Hash)
      else true
      end
      raise error_class, "#{label} must be a #{type}" unless valid
    end

    def validate_enum!(value, schema, error_class:, label:)
      enum = schema["enum"]
      return unless enum && !Array(enum).include?(value)

      raise error_class, "#{label} must be one of: #{Array(enum).join(", ")}"
    end
  end
end
