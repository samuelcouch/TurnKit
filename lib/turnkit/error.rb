# frozen_string_literal: true

module TurnKit
  class Error < StandardError; end
  class AuthorizationError < Error; end
  class BudgetError < Error; end
  class ConfigError < Error; end
  class CompactionError < Error; end
  class InputError < Error; end
  class ModelAccessError < ConfigError; end
  class ModelError < Error; end
  class StoreError < Error; end
  class LostClaim < Error; end
  class ToolError < Error; end
  class ToolValidationError < ToolError; end
end
