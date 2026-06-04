# frozen_string_literal: true

module TurnKit
  module Id
    PREFIXES = {
      conversation: "conv",
      message: "msg",
      turn: "turn",
      tool_execution: "tool"
    }.freeze

    module_function

    def generate(type)
      prefix = PREFIXES.fetch(type)
      "#{prefix}_#{SecureRandom.hex(12)}"
    end
  end
end
