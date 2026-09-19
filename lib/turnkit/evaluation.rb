# frozen_string_literal: true

module TurnKit
  # Deliberately separate from Result: evaluations have no message parts or text.
  class EvaluationResult
    attr_reader :model, :answers, :usage, :receipt_id

    def initialize(model:, answers:, usage:, receipt_id: nil)
      @model, @answers, @usage, @receipt_id = model, answers, usage, receipt_id
    end

    def to_h
      { "model" => model, "answers" => answers, "usage" => usage.to_h }
    end

    def self.from_h(value, receipt_id: nil)
      new(model: value.fetch("model"), answers: value.fetch("answers"),
        usage: Usage.from_h(value.fetch("usage")), receipt_id: receipt_id)
    end
  end

  class EvaluationError < Error
    attr_reader :status, :retry_after, :usage, :model, :http_status

    def initialize(status, retryable: false, retry_after: nil, usage: nil, model: nil, http_status: nil)
      @status, @retryable, @retry_after, @usage, @model = status.to_s, retryable, retry_after, usage, model
      @http_status = http_status
      # Never include provider bodies, URLs, state, question names, or credentials.
      super("evaluation #{@status}")
    end

    def retryable? = @retryable
  end

  module Evaluation
    module_function

    # Canonical JSON also rejects Ruby objects which JSON.generate would stringify.
    def json(value)
      case value
      when Hash
        raise InputError, "evaluation keys must be strings or symbols" unless value.keys.all? { |k| k.is_a?(String) || k.is_a?(Symbol) }
        raise InputError, "duplicate evaluation keys" unless value.keys.map(&:to_s).uniq.size == value.size
        value.transform_keys(&:to_s).sort.to_h.transform_values { |v| json(v) }
      when Array then value.map { |v| json(v) }
      when String, Integer, TrueClass, FalseClass, NilClass then value
      when Float
        raise InputError, "evaluation numbers must be finite" unless value.finite?
        value
      else raise InputError, "evaluation values must be JSON"
      end
    end

    def text?(value) = value.nil? || value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)

    def input!(state:, questions:)
      input = json({ state: state, questions: questions })
      valid = text?(input["state"]) && input["questions"].is_a?(Hash)
      raise InputError, "invalid evaluation input" unless valid
      input["questions"].each do |id, question|
        valid = !id.empty? && question.is_a?(Hash) && (question.keys - %w[type instructions criteria]).empty? &&
          question.key?("instructions") && text?(question["instructions"])
        raise InputError, "invalid evaluation question" unless valid
        criteria = question["criteria"]
        valid = case question["type"]
        when "noul"
          criteria.nil? || (criteria.is_a?(Hash) && (criteria.keys - %w[true false]).empty? && criteria.values.all? { |v| text?(v) })
        when "choice"
          criteria.is_a?(Hash) && criteria.values.all? { |v| text?(v) }
        when "score"
          criteria.is_a?(Array) && criteria.size >= 2 && criteria.all? { |v| text?(v) }
        else false
        end
        raise InputError, "invalid evaluation criteria" unless valid
      end
      input
    end

    def probability?(value) = value.is_a?(Numeric) && value.finite? && value.between?(0, 1)

    def usage(value)
      return unless value.is_a?(Hash) && value.keys.sort == %w[input_tokens output_tokens]
      return unless value.values.all? { |v| v.is_a?(Integer) && v.between?(0, 9_007_199_254_740_991) }
      Usage.new(input_tokens: value["input_tokens"], output_tokens: value["output_tokens"])
    end

    def result!(value, questions:)
      observed = usage(value["usage"]) if value.is_a?(Hash)
      model = value["model"] if value.is_a?(Hash) && value["model"].is_a?(String) && !value["model"].empty?
      invalid = -> { raise EvaluationError.new(:malformed, usage: observed, model: model) }
      invalid.call unless value.is_a?(Hash) && value.keys.sort == %w[answers model usage] && model && observed
      answers = value["answers"]
      invalid.call unless answers.is_a?(Hash) && answers.keys.sort == questions.keys.sort
      answers.each do |id, answer|
        question = questions.fetch(id)
        type = question.fetch("type")
        invalid.call unless answer.is_a?(Hash) && answer["type"] == type
        if type == "noul"
          invalid.call unless answer.keys.sort == %w[noul type] && probability?(answer["noul"])
          next
        end
        keys = type == "choice" ? %w[choice confidence probabilities type] : %w[confidence legend probabilities score type]
        invalid.call unless answer.keys.sort == keys && probability?(answer["confidence"])
        expected = type == "choice" ? question.fetch("criteria").keys : question.fetch("criteria").each_index.map(&:to_s)
        probabilities = answer["probabilities"]
        invalid.call unless probabilities.is_a?(Hash) && probabilities.keys.sort == expected.sort &&
          probabilities.values.all? { |p| probability?(p) } && (probabilities.values.sum - 1).abs <= 0.01
        if type == "choice"
          invalid.call unless expected.include?(answer["choice"])
        else
          score, legend = answer.values_at("score", "legend")
          invalid.call unless score.is_a?(Numeric) && score.finite? && score.between?(0, expected.size - 1) &&
            legend.is_a?(Hash) && legend.keys.sort == expected.sort && legend.values.all? { |v| v.is_a?(String) }
        end
      end
      EvaluationResult.new(model: model, answers: answers, usage: observed)
    end
  end
end
