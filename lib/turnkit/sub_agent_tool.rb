# frozen_string_literal: true

module TurnKit
  class SubAgentTool < Tool
    parameter :task, :string, required: true, description: "The complete task for the sub-agent, including all relevant context."

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

    def call(task:, context:)
      sub_agent = self.class.agent
      parent_turn = context.turn
      lineage = {
        "parent_conversation_id" => parent_turn.conversation.id,
        "parent_turn_id" => parent_turn.id,
        "parent_tool_execution_id" => context.execution.id
      }
      conversation = sub_agent.conversation(metadata: lineage)
      trigger = conversation.say(task, metadata: lineage)
      child = conversation.run!(
        trigger_message_id: trigger.id,
        budget: parent_turn.budget,
        parent_turn: parent_turn,
        parent_tool_execution: context.execution,
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
