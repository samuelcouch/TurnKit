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
# TurnKit.on_event = ->(event) { Rails.logger.info("turnkit.#{event.type} #{event.payload.inspect}") }

# TurnKit builds each system prompt from these sections by default.
# TurnKit.prompt_sections = %i[agent instructions behavior loaded_skills available_skills tools subject environment]
# TurnKit.prompt_behavior = "Custom behavior instructions."
# TurnKit.available_skills = TurnKit::Skill.from_directory(Rails.root.join("app/ai/skills"))

# Suggested Rails convention:
# - app/ai/agents/* builds TurnKit::Agent objects for your workflows.
# - app/ai/tools/* defines TurnKit::Tool subclasses.
# - app/ai/skills/* stores reusable Markdown skill files.
