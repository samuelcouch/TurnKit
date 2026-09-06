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

    def self.build_child(task:, context:)
      sub_agent = agent
      parent_turn = context.turn
      lineage = {
        "parent_conversation_id" => parent_turn.conversation.id,
        "parent_turn_id" => parent_turn.id,
        "parent_tool_execution_id" => context.execution.id,
        "principal" => context.principal
      }
      store = parent_turn.store
      record = store.create_conversation("agent_name" => sub_agent.name, "model" => sub_agent.effective_model, "metadata" => lineage)
      conversation = Conversation.new(agent: sub_agent, record: record, store: store, model: sub_agent.effective_model, metadata: lineage)
      trigger = conversation.say(task, metadata: lineage)
      conversation.build_turn(
        trigger_message_id: trigger.id,
        budget: parent_turn.budget,
        parent_turn: parent_turn,
        parent_tool_execution: context.execution,
        depth: parent_turn.depth + 1,
        model: sub_agent.effective_model,
        agent: sub_agent,
        principal: context.principal,
        on_event: parent_turn.agent.effective_on_event
      )
    end

    def self.result(record)
      { "conversation_id" => record.fetch("conversation_id"), "turn_id" => record.fetch("id"),
        "status" => record.fetch("status"), "result" => record["output_text"].to_s,
        "output_data" => record["output_data"], "error" => record["error"] }.compact
    end

    def call(task:, context:)
      Authorization.authorize!(:launch_agent, principal: context.principal, turn: context.turn,
        agent: self.class.agent, arguments: { "task" => task })
      child = self.class.build_child(task: task, context: context)
      child.run!
      SubAgentTool.result(child.store.load_turn(child.id))
    end
  end
end
