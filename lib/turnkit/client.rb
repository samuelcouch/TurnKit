# frozen_string_literal: true

module TurnKit
  class Client
    def validate!(model:)
      true
    end

    def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
      raise NotImplementedError
    end
  end
end
