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

        class << self
          attr_reader :agent
        end
      end
    end

    def call(task:, context: nil, turnkit_context:)
      sub_agent = self.class.agent
      parent_turn = turnkit_context.turn
      conversation = parent_turn.conversation
      prompt = [ task, context ].compact.join("\n\n")
      trigger = conversation.append_message(role: "user", kind: "text", text: prompt, turn_id: parent_turn.id)
      child = conversation.run!(
        trigger_message_id: trigger.id,
        budget: parent_turn.budget,
        parent_turn: parent_turn,
        parent_tool_execution: turnkit_context.execution,
        depth: parent_turn.depth + 1,
        model: sub_agent.effective_model,
        agent: sub_agent
      )
      { "turn_id" => child.id, "status" => child.status, "result" => child.output_text }
    end
  end
end
