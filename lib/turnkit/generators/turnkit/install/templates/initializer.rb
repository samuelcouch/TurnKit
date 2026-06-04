# frozen_string_literal: true

TurnKit.store = TurnKit::ActiveRecordStore.new

TurnKit.conversation_record_class = "Turnkit::Conversation"
TurnKit.turn_record_class = "Turnkit::Turn"
TurnKit.message_record_class = "Turnkit::Message"
TurnKit.tool_execution_record_class = "Turnkit::ToolExecution"

# TurnKit.default_model = "claude-sonnet-4-5"
# TurnKit.max_iterations = 25
# TurnKit.timeout = 300
# TurnKit.max_depth = 3
# TurnKit.max_tool_executions = 100
