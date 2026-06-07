# frozen_string_literal: true

module TurnKit
  class Conversation
    THINKING_UNSET = Object.new.freeze

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

    def run!(trigger_message_id: nil, model: nil, budget: nil, parent_turn: nil, parent_tool_execution: nil, depth: 0, agent: self.agent, thinking: THINKING_UNSET, compact: nil, output_schema: nil, on_event: nil)
      build_turn(trigger_message_id: trigger_message_id, model: model, budget: budget, parent_turn: parent_turn, parent_tool_execution: parent_tool_execution, depth: depth, agent: agent, thinking: thinking, compact: compact, output_schema: output_schema, on_event: on_event).run!
    end

    def build_turn(trigger_message_id: nil, model: nil, budget: nil, parent_turn: nil, parent_tool_execution: nil, depth: 0, agent: self.agent, thinking: THINKING_UNSET, compact: nil, output_schema: nil, on_event: nil)
      snapshot = latest_message_sequence
      effective_thinking = thinking.equal?(THINKING_UNSET) ? agent.effective_thinking : Agent.normalize_thinking(thinking)
      options = { "trigger_message_id" => trigger_message_id }.compact
      options["thinking"] = effective_thinking
      options["compact"] = compact unless compact.nil?
      options["output_schema"] = output_schema || agent.output_schema if output_schema || agent.output_schema
      record = store.create_turn(
        "conversation_id" => id,
        "agent_name" => agent.name,
        "parent_turn_id" => parent_turn&.id,
        "parent_tool_execution_id" => parent_tool_execution&.id,
        "root_turn_id" => parent_turn&.root_turn_id,
        "context_message_sequence" => snapshot,
        "status" => "pending",
        "model" => model || self.model || agent.effective_model,
        "options" => options
      )
      Turn.new(agent: agent, conversation: self, record: record, store: store, budget: budget, depth: depth, on_event: on_event)
    end

    def compact!(focus: nil, model: nil)
      overrides = { "model" => model }.compact
      TurnKit::Compaction.compact!(self, agent: agent, focus: focus, auto: false, overrides: overrides)
    end

    def messages
      store.list_messages(id).map { |attrs| Message.new(attrs) }
    end

    def usage
      Usage.from_records(store.list_turns(conversation_id: id))
    end

    def cost
      Cost.from_records(store.list_turns(conversation_id: id))
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
