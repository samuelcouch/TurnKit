# frozen_string_literal: true

module TurnKit
  class Client
    def validate!(model:)
      true
    end

    def chat(model:, messages:, tools:, instructions:, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
      raise NotImplementedError
    end

    def paint(prompt:, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: nil, on_event: nil)
      raise NotImplementedError
    end
  end
end
