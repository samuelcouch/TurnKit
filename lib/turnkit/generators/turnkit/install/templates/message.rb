# frozen_string_literal: true

module Turnkit
  class Message < ApplicationRecord
    self.table_name = "<%= table_prefix %>_messages"

    belongs_to :conversation, class_name: "Turnkit::Conversation", foreign_key: :conversation_uid, primary_key: :uid, inverse_of: :messages
    belongs_to :turn, class_name: "Turnkit::Turn", foreign_key: :turn_uid, primary_key: :uid, optional: true, inverse_of: :messages
    belongs_to :tool_execution, class_name: "Turnkit::ToolExecution", foreign_key: :tool_execution_uid, primary_key: :uid, optional: true
  end
end
