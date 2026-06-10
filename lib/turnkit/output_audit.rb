# frozen_string_literal: true

module TurnKit
  class OutputAudit
    Violation = Struct.new(:rule, :message, :metadata, keyword_init: true) do
      def to_h
        { "rule" => rule.to_s, "message" => message.to_s, "metadata" => metadata || {} }
      end
    end

    Result = Struct.new(:violations, keyword_init: true) do
      def clean?
        violations.empty?
      end

      def messages
        violations.map(&:message)
      end

      def to_h
        { "clean" => clean?, "violations" => violations.map(&:to_h) }
      end
    end

    def self.check(output, constraints: [], context: {})
      new(output, constraints: constraints, context: context).check
    end

    def initialize(output, constraints: [], context: {})
      @output = output
      @constraints = Array(constraints)
      @context = context || {}
    end

    def check
      Result.new(violations: constraints.flat_map { |constraint| normalize(check_constraint(constraint)) })
    end

    private
      attr_reader :output, :constraints, :context

      def check_constraint(constraint)
        if constraint.respond_to?(:check)
          call_with_optional_context(constraint.method(:check))
        elsif constraint.respond_to?(:call)
          callable = constraint.is_a?(Proc) ? constraint : constraint.method(:call)
          call_with_optional_context(callable)
        else
          raise ArgumentError, "output constraints must respond to #call or #check"
        end
      end

      def call_with_optional_context(method)
        parameters = method.parameters
        return method.call(output) unless parameters.any? { |kind, _| %i[key keyreq keyrest].include?(kind) }
        return method.call(output, **context) if parameters.any? { |kind, _| kind == :keyrest }

        accepted = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
        method.call(output, **context.slice(*accepted))
      end

      def normalize(value)
        case value
        when nil, false, true
          []
        when Violation
          [ value ]
        when Result
          value.violations
        when String
          [ Violation.new(rule: "output_constraint", message: value, metadata: {}) ]
        when Hash
          [ violation_from_hash(value) ]
        else
          if value.respond_to?(:to_ary)
            value.to_ary.flat_map { |item| normalize(item) }
          else
            raise ArgumentError, "output constraint returned unsupported value: #{value.class}"
          end
        end
      end

      def violation_from_hash(value)
        attrs = value.transform_keys(&:to_s)
        Violation.new(
          rule: attrs["rule"] || "output_constraint",
          message: attrs["message"] || attrs["error"] || "output constraint failed",
          metadata: attrs["metadata"] || attrs.reject { |key, _| %w[rule message error].include?(key) }
        )
      end
  end
end
