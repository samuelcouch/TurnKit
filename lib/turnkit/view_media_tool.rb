# frozen_string_literal: true

module TurnKit
  class ViewMediaTool < Tool
    class << self
      %i[model provider output_schema params].each do |name|
        define_method(name) do |value = nil|
          instance_variable_set("@#{name}", value) unless value.nil?
          instance_variable_get("@#{name}")
        end
      end
    end

    def call(turnkit_context:, **arguments)
      turnkit_context.turn.view_media(
        media(**arguments),
        objective: objective(**arguments),
        model: self.class.model,
        provider: self.class.provider,
        output_schema: self.class.output_schema,
        params: self.class.params || {},
        metadata: metadata(**arguments)
      ).to_h
    end

    def metadata(**)
      {}
    end
  end
end
