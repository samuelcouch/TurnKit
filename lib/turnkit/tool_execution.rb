# frozen_string_literal: true

module TurnKit
  class ToolExecution
    STATUSES = Record::TOOL_EXECUTION_STATUSES

    attr_reader :id, :turn_id, :tool_call_id, :tool_name, :status
    attr_reader :arguments, :result, :error, :started_at, :completed_at

    def initialize(attributes = {})
      attrs = attributes.transform_keys(&:to_s)
      @id = attrs.fetch("id")
      @turn_id = attrs.fetch("turn_id")
      @tool_call_id = attrs.fetch("tool_call_id")
      @tool_name = attrs.fetch("tool_name")
      @status = attrs.fetch("status")
      @arguments = attrs["arguments"] || {}
      @result = attrs["result"]
      @error = attrs["error"]
      @started_at = attrs["started_at"]
      @completed_at = attrs["completed_at"]
    end

    STATUSES.each do |state|
      define_method("#{state}?") { status == state }
    end
  end
end
