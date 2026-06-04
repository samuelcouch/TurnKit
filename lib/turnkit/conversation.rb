# frozen_string_literal: true

module TurnKit
  class Conversation
    attr_reader :agent, :id, :store, :model, :subject, :metadata

    def initialize(agent:, record:, store:, model:, subject: nil, metadata: {})
      @agent = agent
      @record = record.transform_keys(&:to_s)
      @id = @record.fetch("id")
      @store = store
      @model = model
      @subject = subject
      @metadata = metadata || {}
    end

    def say(text, metadata: {})
      append_message(role: "user", kind: "text", text: text, metadata: metadata)
    end

    def ask(text, async: false, **options)
      trigger = say(text)
      turn = build_turn(trigger_message_id: trigger.id, **options)
      async ? turn : turn.run!
    end

    def run!(trigger_message_id: nil, model: nil, budget: nil, parent_turn: nil, parent_tool_execution: nil, depth: 0, agent: self.agent)
      build_turn(trigger_message_id: trigger_message_id, model: model, budget: budget, parent_turn: parent_turn, parent_tool_execution: parent_tool_execution, depth: depth, agent: agent).run!
    end

    def build_turn(trigger_message_id: nil, model: nil, budget: nil, parent_turn: nil, parent_tool_execution: nil, depth: 0, agent: self.agent)
      snapshot = latest_message_sequence
      record = store.create_turn(
        "conversation_id" => id,
        "agent_name" => agent.name,
        "parent_turn_id" => parent_turn&.id,
        "parent_tool_execution_id" => parent_tool_execution&.id,
        "root_turn_id" => parent_turn&.root_turn_id,
        "context_message_sequence" => snapshot,
        "status" => "pending",
        "model" => model || self.model || agent.effective_model,
        "options" => { "trigger_message_id" => trigger_message_id }.compact
      )
      Turn.new(agent: agent, conversation: self, record: record, store: store, budget: budget, depth: depth)
    end

    def messages
      store.list_messages(id).map { |attrs| Message.new(attrs) }
    end

    def messages_for_turn(turn)
      store.list_messages(id, through_sequence: turn.context_message_sequence, turn_id: turn.id).map { |attrs| Message.new(attrs) }
    end

    def append_message(role:, kind:, text: nil, content: nil, turn_id: nil, tool_execution_id: nil, metadata: {})
      attrs = store.append_message(
        "conversation_id" => id,
        "turn_id" => turn_id,
        "role" => role,
        "kind" => kind,
        "text" => text,
        "content" => content,
        "tool_execution_id" => tool_execution_id,
        "metadata" => metadata
      )
      Message.new(attrs)
    end

    def latest_message_sequence
      if store.respond_to?(:latest_message_sequence)
        store.latest_message_sequence(id)
      else
        messages.map(&:sequence).max.to_i
      end
    end
  end
end
