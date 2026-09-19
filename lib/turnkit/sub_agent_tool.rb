# frozen_string_literal: true

module TurnKit
  # Runs a child agent in a fresh conversation and returns only its final result.
  # `SubAgentTool.for(agent)` exposes an agent as a tool taking `task`. Subclasses
  # declare their own parameters and override `task_for` to assemble the task in
  # Ruby, so bulk data (file contents, records) reaches the child without ever
  # entering the parent model's context. The child comes from the `agent` class
  # macro or an instance-level `agent` override.
  class SubAgentTool < Tool
    class << self
      def agent(value = nil)
        @agent = value if value
        @agent || (superclass < SubAgentTool ? superclass.agent : nil)
      end

      def for(agent)
        sub_agent = agent
        Class.new(self) do
          agent sub_agent
          tool_name sub_agent.name
          description sub_agent.description.empty? ? "Delegate work to #{sub_agent.name}." : sub_agent.description
          usage_hint "Use when work can be delegated independently to #{sub_agent.name}. Pass a complete task and only relevant context."
          parameter :task, :string, required: true, description: "The complete task for the sub-agent, including all relevant context."
        end
      end

      def delegates?(tool)
        tool.is_a?(self) || (tool.is_a?(Class) && tool <= self)
      end

      def result(record)
        { "conversation_id" => record.fetch("conversation_id"), "turn_id" => record.fetch("id"),
          "status" => record.fetch("status"), "result" => record["output_text"].to_s,
          "output_metadata" => record.dig("options", "state", "output_metadata"),
          "output_data" => record["output_data"], "error" => record["error"] }.compact
      end
    end

    def agent = self.class.agent

    def task_for(**arguments)
      arguments.fetch(:task)
    end

    def build_child(task:, context:)
      parent_turn = context.turn
      lineage = {
        "parent_conversation_id" => parent_turn.conversation.id,
        "parent_turn_id" => parent_turn.id,
        "parent_tool_execution_id" => context.execution.id,
        "principal" => context.principal
      }
      store = parent_turn.store
      record = store.create_conversation("agent_name" => agent.name, "model" => agent.effective_model, "metadata" => lineage)
      conversation = Conversation.new(agent: agent, record: record, store: store, model: agent.effective_model, metadata: lineage)
      trigger = conversation.say(task, metadata: lineage)
      parent_turn.emit("sub_agent.delegated", id: context.execution.tool_call_id, name: agent.name,
        conversation_id: record.fetch("id"), task_chars: task.length)
      conversation.build_turn(
        trigger_message_id: trigger.id,
        budget: parent_turn.budget,
        parent_turn: parent_turn,
        parent_tool_execution: context.execution,
        depth: parent_turn.depth + 1,
        model: agent.effective_model,
        agent: agent,
        principal: context.principal,
        on_event: parent_turn.agent.effective_on_event
      )
    end

    def call(context:, **arguments)
      Authorization.authorize!(:launch_agent, principal: context.principal, turn: context.turn,
        agent: agent, arguments: arguments.transform_keys(&:to_s))
      child = build_child(task: task_for(**arguments), context: context)
      child.run!
      SubAgentTool.result(child.store.load_turn(child.id))
    end
  end
end
