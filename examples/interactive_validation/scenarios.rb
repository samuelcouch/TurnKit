# frozen_string_literal: true

require_relative "app"
require "open3"

module InteractiveValidation
  module Scenarios
    extend self

    def check(value, label)
      raise "FAIL: #{label}" unless value
    end

    def eventually(label)
      Timeout.timeout(150) do
        loop do
          value = yield
          return value if value
          sleep 0.05
        end
      end
    rescue Timeout::Error
      raise "Timed out: #{label}; inspect persisted iv_evidence and worker logs"
    end

    def gate(turn, name = "response_1", crash: false)
      Barrier.create!(turn_uid: turn.id, name: name, crash: crash)
    end

    def entered(turn, name = "response_1")
      eventually("#{name} entered") do
        row = TurnKit.store.load_turn(turn.id)
        check(row["status"] != "failed", "turn failed before barrier: #{row['error']}")
        Barrier.find_by(turn_uid: turn.id, name: name, entered: true)
      end
    end

    def release(turn, name = "response_1")
      Barrier.find_by!(turn_uid: turn.id, name: name).update!(released: true)
    end

    def finished(turn)
      eventually("completed turn") do
        current = TurnKit.load_turn(turn.respond_to?(:id) ? turn.id : turn)
        check(!current.failed? && !current.cancelled?, "terminal failure #{TurnKit.store.load_turn(current.id)['error']}")
        current if current.completed?
      end
    end

    def paused(turn)
      eventually("pause acknowledged") { TurnKit.load_turn(turn.id).paused? }
      check(TurnKit.store.load_turn(turn.id)["claim_token"].nil?, "pause releases claim")
    end

    def records(turn)
      Evidence.where(kind: "provider", turn_uid: turn.id).order(:id).map(&:data)
    end

    def reload_snapshot(turn)
      output, error, status = Open3.capture3(RbConfig.ruby, __FILE__, "snapshot", turn.id)
      check(status.success?, "fresh process snapshot: #{error}")
      JSON.parse(output)
    end

    def snapshot(id)
      turn = TurnKit.load_turn(id)
      conversation = TurnKit.load_conversation(turn.conversation.id)
      { turn_id: id, conversation_id: conversation.id, pid: Process.pid,
        control: turn.control_state, output: turn.output_text,
        messages: conversation.messages_after(0).map(&:to_h), usage: turn.usage.to_h }
    end

    def post_and_steer
      run = TurnKit.resolve_agent("validation_reader").run("Call read_evidence with section old once, then summarize.", principal: "executor", async: true)
      gate(run)
      run.perform_later
      entered(run)
      check(records(run).first.fetch("output").any? { |item| item["type"] == "function_call" }, "real stale tool proposal")
      conversation = TurnKit.load_conversation(run.turn.conversation.id)
      delivery = conversation.post("Call read_evidence with section next, then answer NEXT_2031 using the finding.", key: "post:#{run.id}", principal: "sender")
      check(delivery["source_conversation_id"] == conversation.id, "destination post requires no fake sender")
      check(conversation.post(delivery.dig("payload", "text"), key: delivery["key"], principal: "sender") == delivery, "post idempotency")
      check(conversation.input_status(delivery["id"])["status"] == "pending", "next input pending")
      first = run.steer!("Do not use tools. Reply exactly STEERED_37.", key: "focus", principal: "owner").first
      second = run.steer!("Use the exact spelling STEERED_37.", key: "spelling", principal: "owner").first
      check([first["sequence"], second["sequence"]] == [1, 2], "ordered durable receipts")
      release(run)
      result = finished(run)
      check(result.output_text == "STEERED_37", "revised output replaces stale plan")
      check(Evidence.where(kind: "tool", turn_uid: run.id).count == 0, "stale proposals never executed")
      request = records(run).fetch(1)
      check(request.fetch("input").last(3).map { |item| item["type"] || item["role"] } == %w[function_call_output user user], "stale call closed before human inputs")
      check(request.fetch("input").none? { |item| item["content"] == delivery.dig("payload", "text") }, "frozen next-turn context")
      applied = eventually("durable next-turn acknowledgment") do
        value = conversation.input_status(delivery["id"])
        value if value["status"] == "applied"
      end
      next_turn = finished(applied.dig("application", "turn_id"))
      check(next_turn.id != run.id, "post applied in next turn")
      check(next_turn.output_text.include?("NEXT_2031"), "next-turn output")
      check(applied.dig("application", "request_id") == records(next_turn).first["request_id"], "delivery request identity")
      check(Evidence.where(kind: "tool", turn_uid: next_turn.id).first.data["principal"] == "executor", "sender does not replace receiving principal")
      inputs = run.control_state.dig("controls", "inputs")
      check(inputs.all? { |input| input["message_id"] && input["request_id"] == request["request_id"] }, "message/request receipts")
      check(run.steer!(first["text"], key: "focus", principal: "owner").first == inputs.first, "terminal retry receipt")
      begin
        run.steer!("late", key: "late")
        raise "terminal steering accepted"
      rescue TurnKit::Error
      end
      snap = reload_snapshot(result)
      check(snap["pid"] != Process.pid, "fresh process read")
      check(snap["messages"].none? { |m| m["content"].any? { |p| %w[provider thinking].include?(p["type"]) } }, "UI projection excludes opaque provider state")
      sequences = snap["messages"].map { |m| m["sequence"] }
      check(sequences == sequences.sort.uniq, "conversation sequence cursor order")
      cursor = sequences[2]
      check(conversation.messages_after(cursor).map(&:sequence) == sequences.select { |n| n > cursor }, "incremental catchup")
      { turn_id: run.id, next_turn_id: next_turn.id, delivery: applied, inputs: inputs, stale_tools_executed: 0, catchup_messages: sequences.length }
    end

    def pause_model
      run = TurnKit.resolve_agent("validation_plain").run("Reply exactly KEPT_CANDIDATE.", async: true)
      gate(run)
      run.perform_later
      entered(run)
      run.pause!
      check(run.reload.running? && run.control_state.dig("controls", "pause_requested"), "pause intent before acknowledgment")
      release(run)
      paused(run)
      before = TurnKit.store.load_turn(run.id)
      check(before.dig("options", "state", "phase") == "output" && before["output_text"].nil?, "candidate retained but unpublished")
      TurnKit::Background.reconcile(before: Time.now.utc + 1)
      TurnKit::Job.perform_later(run.id)
      check(reload_snapshot(run).dig("control", "status") == "paused", "reconcile does not unpause")
      run.resume!
      run.resume!
      result = finished(run)
      check(result.output_text == "KEPT_CANDIDATE", "candidate published on resume")
      check(records(run).length == 1 && result.usage.to_h == TurnKit::Usage.from_h(before["usage"]).to_h, "no new call or reset usage")
      { turn_id: run.id, provider_calls: 1, usage: result.usage.to_h }
    end

    def pause_tool
      run = TurnKit.resolve_agent("validation_reader").run("In a single response call read_evidence twice: first section first, then section second. Do not wait for the first result to propose the second. Then summarize.", async: true)
      gate(run, "tool_first")
      run.perform_later
      entered(run, "tool_first")
      check(records(run).first.fetch("output").count { |item| item["type"] == "function_call" } == 2, "two real parallel proposals")
      run.pause!
      run.steer!("Do not call more tools. Using the committed finding, reply exactly TOOL_2031.", key: "tool-focus")
      release(run, "tool_first")
      paused(run)
      executions = TurnKit.load_turn(run.id).tool_executions
      check(executions.first.result["finding"].include?("2031"), "in-flight read result committed")
      run.resume!
      result = finished(run)
      check(result.output_text == "TOOL_2031", "revised answer uses committed finding")
      check(result.tool_executions.map(&:status) == %w[completed cancelled], "remaining stale tool skipped")
      check(Evidence.where(kind: "tool", turn_uid: run.id).count == 1, "read tool executes only once")
      { turn_id: run.id, tools: result.tool_executions.map { |e| { id: e.id, status: e.status } } }
    end

    def approval_gate
      run = TurnKit.resolve_agent("validation_plain").run("Reply exactly APPROVED", async: true).pause!.perform_later
      delivery = run.turn.conversation.post("Reply exactly FOLLOWUP", key: "gate:#{run.id}")
      # A real queued job proves the worker saw the gate, without a timed guess.
      TurnKit::Background.reconcile
      eventually("Sidekiq observed approval gate") { Evidence.where(kind: "job", turn_uid: run.id).exists? }
      check(run.reload.paused? && records(run).empty?, "pre-submission approval gate")
      check(run.turn.conversation.input_status(delivery["id"])["status"] == "pending", "post cannot bypass approval")
      run.resume!
      check(finished(run).output_text == "APPROVED", "approved original output")
      applied = eventually("approval followup") do
        receipt = run.turn.conversation.input_status(delivery["id"])
        receipt if receipt["status"] == "applied"
      end
      check(finished(applied.dig("application", "turn_id")).output_text == "FOLLOWUP", "followup after approval")
      { turn_id: run.id, delivery: applied }
    end

    def child_join
      run = TurnKit.resolve_agent("validation_parent").run("Call validation_child once with task 'Reply exactly CHILD_FINDING_37'. Wait for its result, then include it in your final answer.", async: true).perform_later
      child = eventually("joined child") do
        rows = run.child_turn_records
        TurnKit.load_turn(rows.first["id"]) if rows.any? && run.reload.waiting?
      end
      entered(child)
      independent = TurnKit.resolve_agent("validation_plain").run("Reply exactly INDEPENDENT.", async: true).pause!.perform_later
      run.pause!(descendants: :cascade)
      check(run.reload.paused? && child.reload.running?, "subtree acknowledgment is not just parent acknowledgment")
      check(child.control_state.dig("controls", "pause_requested"), "cascade includes running child")
      run.steer!("Do not call additional tools. Preserve CHILD_FINDING_37 and reply exactly NEW_FOCUS CHILD_FINDING_37.", key: "tree", descendants: :cascade)
      release(child)
      paused(child)
      check(TurnKit.store.list_waits(turn_id: run.id).length == 1, "joined wait persists across pause")
      run.resume!(descendants: :cascade)
      result = finished(run)
      check(result.output_text == "NEW_FOCUS CHILD_FINDING_37", "parent replans after joined findings")
      check(finished(child).output_text.include?("CHILD_FINDING_37"), "child finding retained")
      check(result.tool_executions.first.result["result"].include?("CHILD_FINDING_37"), "completed child result attached to parent")
      check(independent.reload.paused?, "independent root excluded from cascade resume")
      independent.cancel!
      { turn_id: run.id, child_id: child.id, independent_id: independent.id, waits: TurnKit.store.list_waits(turn_id: run.id).length }
    end

    def retain_join
      run = TurnKit.resolve_agent("validation_parent").run("Call validation_child once with task 'Reply exactly CHILD_FINDING_37'. Wait for its result and report it.", async: true).perform_later
      child = eventually("retained child") do
        rows = run.child_turn_records
        TurnKit.load_turn(rows.first["id"]) if rows.any? && run.reload.waiting?
      end
      entered(child)
      run.pause!
      release(child)
      finished(child)
      check(reload_snapshot(run).dig("control", "status") == "paused", "completed child does not unpause retained parent")
      run.steer!("Do not call more tools. Include the completed child's finding and reply exactly RETAINED CHILD_FINDING_37.", key: "retained")
      run.resume!
      check(finished(run).output_text == "RETAINED CHILD_FINDING_37", "parent preserves findings and revises publication")
      { turn_id: run.id, child_id: child.id }
    end

    def launch_cascade
      run = TurnKit.resolve_agent("validation_launcher").run("Use launch_agent once (not validation_child directly), agent_name validation_child, task 'Reply exactly LAUNCH_CHILD', callback false. Then reply exactly LAUNCHED.", async: true)
      gate(run, "response_2")
      run.perform_later
      entered(run, "response_2")
      child = TurnKit.load_turn(run.child_turn_records.fetch(0).fetch("id"))
      entered(child)
      check(child.parent_turn_id == run.id && TurnKit.store.list_waits(turn_id: run.id).empty?, "independent scheduling retains parent lineage without join")
      child.pause! # An individually paused descendant is also resumed by cascade.
      run.pause!(descendants: :cascade)
      release(run, "response_2")
      release(child)
      paused(run)
      paused(child)
      run.resume!(descendants: :cascade)
      check(finished(run).output_text == "LAUNCHED", "launched parent resumed")
      check(finished(child).output_text == "LAUNCH_CHILD", "cascade resumes individually paused linked child")
      { turn_id: run.id, child_id: child.id, joined: false }
    end

    def cancellation
      run = TurnKit.resolve_agent("validation_plain").run("Reply exactly MUST_NOT_PUBLISH.", async: true)
      gate(run)
      run.perform_later
      entered(run)
      run.pause!
      receipt = run.steer!("Do not publish.", key: "cancelled").first
      run.cancel!
      run.resume!
      release(run)
      eventually("cancelled worker finished") { Evidence.where(kind: "job", turn_uid: run.id).exists? }
      state = reload_snapshot(run)
      check(state.dig("control", "status") == "cancelled" && state["output"] == "", "cancellation terminal and unpublished")
      check(state["messages"].none? { |m| m["role"] == "assistant" || m.dig("metadata", "steering_id") }, "late real response fenced")
      check(run.steer!("Do not publish.", key: "cancelled").first == receipt, "cancelled retry returns durable receipt")
      { turn_id: run.id, provider_calls: records(run).length, status: "cancelled" }
    end

    def recovery
      run = TurnKit.resolve_agent("validation_plain").run("Reply exactly RECOVERED.", async: true)
      gate(run, crash: true)
      input = run.steer!("Reply exactly RECOVERED.", key: "recovery").first
      run.perform_later
      barrier = entered(run)
      run.pause!
      receipt = run.control_state.dig("controls", "inputs").first
      check(receipt["message_id"] && receipt["request_id"], "receipt persisted before real response returns")
      release(run)
      eventually("worker exited after real response") { barrier.reload.crashed }
      # Recovery eligibility is advanced explicitly; no clock or executor patch.
      TurnKit::Background.reconcile(before: Time.now.utc + 1)
      check(system("amp", "orb", "service", "restart", ENV.fetch("TURNKIT_VALIDATION_WORKER", "interactive-sidekiq"), out: $stderr), "restart worker")
      paused(run)
      check(TurnKit.load_turn(run.id).conversation.messages.count { |message| message.role == "assistant" } == 0, "uncommitted response fenced")
      run.resume!
      result = finished(run)
      check(result.output_text == "RECOVERED", "recovered output")
      check(records(run).length == 2, "provider request may repeat after worker death")
      check(records(run).map { |r| r["worker_pid"] }.uniq.length == 2, "replacement process performs replay")
      check(result.conversation.messages.count { |m| m.metadata["steering_id"] == input["id"] } == 1, "steering not duplicated")
      check(result.control_state.dig("controls", "inputs").first == receipt, "first reserved request receipt stable")
      { turn_id: run.id, input: receipt, provider_calls: 2, worker_pids: records(run).map { |r| r["worker_pid"] } }
    end

    def native
      paused_tool = pause_tool
      turn = TurnKit.load_turn(paused_tool.fetch(:turn_id))
      check(records(turn).any? { |row| row["opaque_blocks"].positive? }, "provider returned real opaque signatures")
      expected_tokens = records(turn).sum do |row|
        usage = row.fetch("usage")
        usage["totalTokenCount"] || usage.values_at("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens").compact.sum
      end
      check(turn.usage.total_tokens == expected_tokens, "native tokens do not double-count thinking")
      delivery = turn.conversation.post("Reply with the single token RECONNECTED", key: "native:#{turn.id}")
      applied = eventually("native next-turn delivery") do
        status = turn.conversation.input_status(delivery["id"])
        status if status["status"] == "applied"
      end
      next_turn = finished(applied.dig("application", "turn_id"))
      check(next_turn.output_text == "RECONNECTED", "native final-text reasoning replay across turns")

      task = "Call read_evidence once with section recovery, then reply with the single token RECOVERED"
      run = TurnKit.resolve_agent("validation_reader").run(task, async: true)
      gate(run, "response_2", crash: true)
      run.steer!(task, key: "recovery")
      run.perform_later
      barrier = entered(run, "response_2")
      check(run.tool_executions.first.status == "completed", "read committed before real worker death")
      receipt = run.control_state.dig("controls", "inputs").first
      run.pause!
      release(run, "response_2")
      eventually("native worker death") { barrier.reload.crashed }
      TurnKit::Background.reconcile(before: Time.now.utc + 1)
      check(system("amp", "orb", "service", "restart", ENV.fetch("TURNKIT_VALIDATION_WORKER"), out: $stderr), "restart native worker")
      paused(run)
      run.resume!
      result = finished(run)
      check(result.output_text == "RECOVERED", "native recovered output")
      check(records(run).length == 3 && Evidence.where(kind: "tool", turn_uid: run.id).count == 1, "recovery repeats request, not read tool")
      check(records(run).last(2).map { |row| row["worker_pid"] }.uniq.length == 2, "native replacement worker")
      check(result.control_state.dig("controls", "inputs").first == receipt, "native steering receipt unchanged")
      snapshot = reload_snapshot(result)
      check(snapshot["messages"].all? { |message| message["content"].none? { |part| %w[provider thinking].include?(part["type"]) } }, "native fresh-process UI projection")
      { provider: PROVIDER, model: MODEL, effort: EFFORT, ruby_llm: RubyLLM::VERSION,
        pause_tool: paused_tool, next_turn_id: next_turn.id, recovery_turn_id: run.id,
        provider_calls: records(turn).length + records(next_turn).length + records(run).length }
    end
  end
end

command = ARGV.shift || "all"
abort "Live calls require TURNKIT_INTERACTIVE_LIVE=1" unless command == "snapshot" || ENV["TURNKIT_INTERACTIVE_LIVE"] == "1"
names = %w[post_and_steer pause_model pause_tool approval_gate child_join retain_join launch_cascade cancellation recovery]
result = if command == "snapshot"
  InteractiveValidation::Scenarios.snapshot(ARGV.fetch(0))
elsif command == "all"
  names.to_h do |name|
    value = InteractiveValidation::Scenarios.public_send(name)
    warn "PASS #{name}: #{value[:turn_id]}"
    [name, value]
  end
else
  abort "Unknown scenario" unless (names + ["native"]).include?(command)
  { command => InteractiveValidation::Scenarios.public_send(command) }
end
puts JSON.pretty_generate(result)
