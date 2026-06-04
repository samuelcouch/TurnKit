# frozen_string_literal: true

module TurnKit
  class Railtie < Rails::Railtie
    generators do
      require_relative "../generators/turnkit/install_generator"
    end
  end
end
