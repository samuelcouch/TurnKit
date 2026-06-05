# frozen_string_literal: true

module TurnKit
  class PromptContribution
    attr_accessor :stable_prefix, :dynamic_suffix, :section_overrides

    def initialize(stable_prefix: nil, dynamic_suffix: nil, section_overrides: nil)
      @stable_prefix = stable_prefix.to_s
      @dynamic_suffix = dynamic_suffix.to_s
      @section_overrides = (section_overrides || {}).transform_keys(&:to_sym)
    end
  end
end
