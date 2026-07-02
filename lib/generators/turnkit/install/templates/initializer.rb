# frozen_string_literal: true

# Namespaces: TurnKit:: is the gem's domain layer (agents, conversations,
# turns). The generated ActiveRecord models in app/models/turnkit live under
# Turnkit:: and are pure persistence records used by the store below.
#
# Pass custom model class names if you moved or renamed the generated models:
#   TurnKit::ActiveRecordStore.new(conversation_class: "My::Conversation", ...)
TurnKit.store = TurnKit::ActiveRecordStore.new

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
# - app/ai/agents/* builds TurnKit::Agent objects and orchestrator agents.
# - app/ai/tools/* defines TurnKit::Tool subclasses.
# - app/ai/skills/* stores reusable Markdown skill files.
