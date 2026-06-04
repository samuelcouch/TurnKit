# frozen_string_literal: true

module TurnKit
  class Client
    def chat(model:, messages:, tools:, instructions:, temperature: nil, metadata: nil)
      raise NotImplementedError
    end
  end
end
