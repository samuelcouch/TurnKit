# frozen_string_literal: true

module TurnKit
  module Clock
    module_function

    def now
      Time.now.utc
    end
  end
end
