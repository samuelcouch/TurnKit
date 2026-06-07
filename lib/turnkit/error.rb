# frozen_string_literal: true

module TurnKit
  class Error < StandardError; end
  class ConfigError < Error; end
  class CompactionError < Error; end
  class StoreError < Error; end
  class ToolError < Error; end
end
