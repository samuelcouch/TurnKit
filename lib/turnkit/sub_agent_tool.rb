# frozen_string_literal: true

module TurnKit
  class SubAgentTool < Tool
    parameter :task, :string, required: true, description: "The task for the sub-agent to complete."
    parameter :context, :string, required: false, description: "Relevant context for the sub-agent."

    def self.for(agent)
      Class.new(self) do
        @agent = agent
        tool_name agent.name
        description agent.description.empty? ? "Delegate work to #{agent.name}." : agent.description
        usage_hint "Use when work can be delegated independently to #{agent.name}. Pass a complete task and only relevant context."

        class << self
          attr_reader :agent
        end
      end
    end

    def call(task:, context: nil, turnkit_context:)
      sub_agent = self.class.agent
      parent_turn = turnkit_context.turn
      prompt = [ task, context ].compact.join("\n\n")
      conversation = sub_agent.conversation(metadata: {
        "parent_conversation_id" => parent_turn.conversation.id,
        "parent_turn_id" => parent_turn.id,
        "parent_tool_execution_id" => turnkit_context.execution.id
      })
      trigger = conversation.say(prompt, metadata: {
        "parent_conversation_id" => parent_turn.conversation.id,
        "parent_turn_id" => parent_turn.id,
        "parent_tool_execution_id" => turnkit_context.execution.id
      })
      child = conversation.run!(
        trigger_message_id: trigger.id,
        budget: parent_turn.budget,
        parent_turn: parent_turn,
        parent_tool_execution: turnkit_context.execution,
        depth: parent_turn.depth + 1,
        model: sub_agent.effective_model,
        agent: sub_agent,
        on_event: parent_turn.agent.effective_on_event
      )
      error = child.store.load_turn(child.id)["error"] if child.failed?
      { "conversation_id" => conversation.id, "turn_id" => child.id, "status" => child.status, "result" => child.output_text, "output_data" => child.output_data, "error" => error }.compact
    end
  end
end
