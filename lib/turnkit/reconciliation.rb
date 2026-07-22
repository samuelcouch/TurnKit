# frozen_string_literal: true

module TurnKit
  # Reconciles turns abandoned by a dead worker: atomically marks them stale,
  # marks their unfinished tool executions interrupted, and appends synthetic
  # error tool results so the persisted transcript stays structurally complete
  # for continuation. TurnKit never reruns an interrupted tool; the synthetic
  # result tells the continued model the outcome is unknown.
  module Reconciliation
    INTERRUPTED_MESSAGE = "Tool execution was interrupted before a result was recorded. " \
      "It is unknown whether the operation ran; do not assume it did or did not."

    module_function

    def reconcile!(before:)
      TurnKit.store.reconcile_stale_turns(before: before).each do |turn|
        emit("turn.stale", turn)
        executions = interrupt_tool_executions(turn)
        repair_transcript(turn, executions)
      end
    end

    def interrupt_tool_executions(turn)
      store = TurnKit.store
      store.list_tool_executions(turn_id: turn.fetch("id")).map do |execution|
        next execution unless %w[pending running].include?(execution.fetch("status"))

        interrupted = store.claim_tool_execution(
          execution.fetch("id"),
          from: execution.fetch("status"),
          to: "interrupted",
          error: { "message" => "interrupted: worker terminated while the tool was executing" },
          completed_at: Clock.now
        )
        next execution unless interrupted

        emit("tool_call.interrupted", turn, id: interrupted.fetch("tool_call_id"), name: interrupted.fetch("tool_name"), tool_execution_id: interrupted.fetch("id"))
        interrupted
      end
    end

    def repair_transcript(turn, executions)
      store = TurnKit.store
      messages = store.list_messages(turn.fetch("conversation_id"))
      resolved = messages
        .select { |message| message["kind"] == "tool_result" }
        .flat_map { |message| message["content"].map { |part| part["tool_call_id"] } }

      messages
        .select { |message| message["turn_id"] == turn.fetch("id") && message["kind"] == "tool_call" }
        .flat_map { |message| message["content"].select { |part| part["type"] == "tool_call" } }
        .reject { |part| resolved.include?(part["id"]) }
        .each do |part|
          execution = executions.find { |candidate| candidate["tool_call_id"] == part["id"] }
          message = store.append_message(
            "conversation_id" => turn.fetch("conversation_id"),
            "turn_id" => turn.fetch("id"),
            "role" => "tool",
            "kind" => "tool_result",
            "content" => [ { "type" => "tool_result", "tool_call_id" => part["id"], "text" => { "error" => true, "message" => INTERRUPTED_MESSAGE }.to_json, "error" => true } ],
            "tool_execution_id" => execution&.fetch("id"),
            "metadata" => { "tool_name" => part["name"], "interrupted" => true }
          )
          emit("message.created", turn, message_id: message.fetch("id"), role: "tool", kind: "tool_result")
        end
    end

    def emit(type, turn, payload = {})
      TurnKit.on_event&.call(Event.new(type: type, turn_id: turn.fetch("id"), conversation_id: turn.fetch("conversation_id"), payload: payload))
    end
  end
end
