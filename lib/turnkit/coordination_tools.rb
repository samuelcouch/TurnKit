# frozen_string_literal: true

module TurnKit
  # Opt-in tools: the application chooses which agents can address conversations.
  class SendMessageTool < Tool
    tool_name "send_message"
    description "Send a durable message to a conversation and wake it when idle."
    parameter :conversation_id, :string, required: true
    parameter :text, :string, required: true

    def call(conversation_id:, text:, context:)
      Background.send_message(source: context.turn.conversation.id, destination: conversation_id,
        text: text, key: "message:#{context.execution.id}", store: context.turn.store, source_turn_id: context.turn.id, principal: context.principal)
    end
  end

  class LaunchAgentTool < Tool
    tool_name "launch_agent"
    description "Launch a configured sub-agent independently. Returns IDs immediately; optionally receive a completion message."
    parameter :agent_name, :string, required: true
    parameter :task, :string, required: true
    parameter :callback, :boolean, required: false

    def call(agent_name:, task:, callback: false, context:)
      parent = context.turn
      agent = parent.agent.sub_agents.find { |candidate| candidate.name == agent_name }
      raise ToolError, "unknown sub-agent: #{agent_name}" unless agent
      Authorization.authorize!(:launch_agent, principal: context.principal, turn: parent, agent: agent, arguments: { "task" => task, "callback" => callback })
      Authorization.authorize!(:callback, principal: context.principal, turn: parent.id, destination_conversation: parent.conversation.id) if callback
      TurnKit.resolve_agent(agent.name)
      child = nil
      parent.store.atomic do
        existing = parent.store.list_turns(root_turn_id: parent.root_turn_id).find { |row| row["parent_tool_execution_id"] == context.execution.id }
        if existing
          child = existing
        else
          built = SubAgentTool.for(agent).build_child(task: task, context: context)
          options = parent.store.load_turn(built.id).fetch("options")
          options = options.merge("callback_conversation_id" => parent.conversation.id) if callback
          child = parent.store.update_turn(built.id, submitted_at: Clock.now, options: options)
        end
      end
      Background.enqueue(child.fetch("id"))
      SubAgentTool.result(child)
    end
  end

  class WaitTool < Tool
    tool_name "wait_for"
    description "Suspend this background turn until all listed turns finish. Releases the worker while waiting."
    parameter :turn_ids, :array, required: true

    def call(turn_ids:, context:)
      raise ToolError, "wait_for requires a background turn" unless context.turn.background?
      ids = Background.wait(context.turn, turn_ids)
      return :waiting unless Background.ready?(context.turn.store, context.turn.id)

      { "results" => ids.map { |id| SubAgentTool.result(context.turn.store.load_turn(id)) } }
    end
  end
end
