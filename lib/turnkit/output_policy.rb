# frozen_string_literal: true

module TurnKit
  class OutputPolicy
    DEFAULT_SCHEMA = {
      type: "object",
      properties: {
        approved: { type: "boolean" },
        violations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              rule: { type: "string" },
              message: { type: "string" }
            },
            required: [ "rule", "message" ]
          }
        }
      },
      required: [ "approved", "violations" ]
    }.freeze

    attr_reader :name, :content, :model, :thinking, :client

    def self.from_file(path, name: nil, **options)
      new(name: name || File.basename(path, File.extname(path)), content: File.read(path), **options)
    end

    def self.from_skill(skill, **options)
      new(name: skill.key, content: skill.content, **options)
    end

    def initialize(content:, name: "output_policy", model: nil, thinking: nil, client: nil)
      @name = name.to_s
      @content = content.to_s
      @model = model
      @thinking = Agent.normalize_thinking(thinking)
      @client = client
      raise ArgumentError, "content is required" if @content.empty?
    end

    def call(output, run: nil, turn: nil)
      model_name = model || turn&.model || run&.turn&.model || TurnKit.default_model
      result = if turn
        turn.internal_model_call(
          model: model_name,
          messages: audit_messages(output),
          tools: [],
          instructions: audit_instructions,
          thinking: thinking,
          output_schema: DEFAULT_SCHEMA,
          metadata: { output_policy: name },
          purpose: "output_policy",
          client: client
        )
      else
        audit_client = client || TurnKit.client
        audit_client.validate!(model: model_name)
        chat(audit_client, model: model_name, messages: audit_messages(output), tools: [], instructions: audit_instructions, thinking: thinking, output_schema: DEFAULT_SCHEMA, metadata: { output_policy: name })
      end
      data = result.output_data || parse_json(result.text)
      return if data.fetch("approved", false)

      Array(data["violations"]).map do |violation|
        attrs = violation.transform_keys(&:to_s)
        OutputAudit::Violation.new(
          rule: attrs["rule"] || name,
          message: attrs["message"] || "output policy failed",
          metadata: attrs.reject { |key, _| %w[rule message].include?(key) }
        )
      end
    end

    private
      def audit_instructions
        <<~TEXT
          You audit model outputs against the policy below.

          Return only a JSON object matching this shape:
          {"approved":true,"violations":[]}

          Set approved to true only when the output satisfies the policy. For each violation, include a concise rule and message. Do not repair the output. Do not wrap the JSON in Markdown. Do not include commentary before or after the JSON.

          The policy may be a skill; treat its output-facing rules as normative and ignore process steps that are not observable in the output.

          Policy:
          #{content}
        TEXT
      end

      def audit_messages(output)
        [ { role: :user, content: JSON.generate(output: output) } ]
      end

      def chat(client, **kwargs)
        accepted = chat_keyword_names(client)
        kwargs = kwargs.slice(*accepted) unless accepted.include?(:keyrest)
        client.chat(**kwargs)
      end

      def chat_keyword_names(client)
        client.method(:chat).parameters.filter_map do |kind, name|
          return [ :keyrest ] if kind == :keyrest

          name if %i[key keyreq].include?(kind)
        end
      end

      def parse_json(value)
        JSON.parse(extract_json(value.to_s))
      rescue JSON::ParserError
        { "approved" => false, "violations" => [ { "rule" => name, "message" => "output policy returned invalid JSON" } ] }
      end

      def extract_json(value)
        text = value.strip
        return text if text.start_with?("{") && text.end_with?("}")

        fenced = text[/```(?:json)?\s*(\{.*?\})\s*```/m, 1]
        return fenced if fenced

        object = text[/\{.*\}/m]
        object || text
      end
  end
end
