# frozen_string_literal: true

module TurnKit
  # The adapter contract. TurnKit calls clients with the full keyword
  # signatures below. Custom adapters should subclass TurnKit::Client (or
  # accept the same keywords) and must not execute tools themselves; TurnKit
  # runs tools and persists their results. Messages may include :provider_parts
  # for opaque continuation state from Result parts with type "provider".
  # Adapters should consume only their own provider kind, never display it.
  class Client
    def validate!(model:)
      true
    end

    # Opt in to durable, append-only dynamic context messages. The runtime
    # then passes empty dynamic_instructions; ordinary clients keep the
    # existing separate-instructions contract and do not see these messages.
    def dynamic_context_in_history?(model:)
      false
    end

    def chat(model:, messages:, tools:, instructions:, dynamic_instructions: nil, temperature: nil, thinking: nil, output_schema: nil, metadata: nil, on_event: nil)
      raise NotImplementedError
    end

    def paint(prompt:, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: nil, on_event: nil)
      raise NotImplementedError
    end

    def view_media(media:, objective:, model:, provider: nil, output_schema: nil, params: {}, metadata: nil, on_event: nil)
      raise NotImplementedError
    end
  end
end
