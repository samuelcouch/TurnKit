# frozen_string_literal: true

module TurnKit
  class ImageTool < Tool
    class << self
      %i[model provider size assume_model_exists params].each do |name|
        define_method(name) do |value = nil|
          instance_variable_set("@#{name}", value) unless value.nil?
          instance_variable_get("@#{name}")
        end
      end
    end

    def call(context:, **arguments)
      context.turn.paint(
        prompt(**arguments),
        model: self.class.model,
        provider: self.class.provider,
        size: self.class.size,
        assume_model_exists: self.class.assume_model_exists,
        params: self.class.params || {},
        metadata: metadata(**arguments)
      ).to_h
    end

    def metadata(**)
      {}
    end
  end
end
