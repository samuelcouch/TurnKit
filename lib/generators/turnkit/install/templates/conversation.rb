# frozen_string_literal: true

module Turnkit
  class Conversation < ApplicationRecord
    self.table_name = "<%= table_prefix %>_conversations"

    has_many :turns, class_name: "Turnkit::Turn", foreign_key: :conversation_uid, primary_key: :uid, dependent: :destroy, inverse_of: :conversation
    has_many :messages, class_name: "Turnkit::Message", foreign_key: :conversation_uid, primary_key: :uid, dependent: :destroy, inverse_of: :conversation
  end
end
