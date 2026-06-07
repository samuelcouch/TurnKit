# frozen_string_literal: true

module TurnKit
  class Error < StandardError; end
  class ConfigError < Error; end
  class CompactionError < Error; end
  class ModelAccessError < ConfigError; end
  class StoreError < Error; end
  class ToolError < Error; end
  class ToolValidationError < ToolError; end
end
