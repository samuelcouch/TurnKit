# frozen_string_literal: true

module Turnkit
  class ToolExecution < ApplicationRecord
    self.table_name = "<%= table_prefix %>_tool_executions"

    belongs_to :turn, class_name: "Turnkit::Turn", foreign_key: :turn_uid, primary_key: :uid, inverse_of: :tool_executions
    has_many :messages, class_name: "Turnkit::Message", foreign_key: :tool_execution_uid, primary_key: :uid, dependent: :nullify
  end
end
