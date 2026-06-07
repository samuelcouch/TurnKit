# frozen_string_literal: true

module TurnKit
  class Event
    attr_reader :type, :turn_id, :conversation_id, :payload, :created_at

    def initialize(type:, turn_id:, conversation_id:, payload: {}, created_at: Clock.now)
      @type = type.to_s
      @turn_id = turn_id
      @conversation_id = conversation_id
      @payload = payload || {}
      @created_at = created_at
    end

    def to_h
      {
        "type" => type,
        "turn_id" => turn_id,
        "conversation_id" => conversation_id,
        "payload" => payload,
        "created_at" => created_at
      }
    end
  end
end
