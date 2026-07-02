# frozen_string_literal: true

module Turnkit
  class Turn < ApplicationRecord
    self.table_name = "<%= table_prefix %>_turns"

    belongs_to :conversation, class_name: "Turnkit::Conversation", foreign_key: :conversation_uid, primary_key: :uid, inverse_of: :turns
    belongs_to :parent_turn, class_name: "Turnkit::Turn", foreign_key: :parent_turn_uid, primary_key: :uid, optional: true
    belongs_to :parent_tool_execution, class_name: "Turnkit::ToolExecution", foreign_key: :parent_tool_execution_uid, primary_key: :uid, optional: true

    has_many :messages, class_name: "Turnkit::Message", foreign_key: :turn_uid, primary_key: :uid, dependent: :nullify, inverse_of: :turn
    has_many :tool_executions, class_name: "Turnkit::ToolExecution", foreign_key: :turn_uid, primary_key: :uid, dependent: :destroy, inverse_of: :turn
  end
end
