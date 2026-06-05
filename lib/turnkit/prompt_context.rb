# frozen_string_literal: true

module TurnKit
  PromptBuildContext = Struct.new(
    :agent,
    :turn,
    :conversation,
    :model,
    keyword_init: true
  )

  LiveContextContribution = Struct.new(
    :name,
    :content,
    :trusted,
    :max_chars,
    keyword_init: true
  ) do
    def trusted?
      trusted ? true : false
    end
  end
end
