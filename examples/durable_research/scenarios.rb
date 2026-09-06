# frozen_string_literal: true

require_relative "app"
require "open3"

module DurableResearch
  module Scenarios
    extend self

    def check(condition, message)
      raise "FAIL: #{message}" unless condition
    end

    def eventually(label)
      Timeout.timeout(90) do
        loop do
          value = yield
          return value if value
          sleep 0.1
        end
      end
    rescue Timeout::Error
      raise "Timed out: #{label}. Check the worker logs and solid_queue_failed_executions."
    end

    def finished(id)
      eventually("turn #{id}") do
        turn = TurnKit.load_turn(id)
        check(!turn.failed? && !turn.cancelled?, "#{id}: #{TurnKit.store.load_turn(id)['error']}")
        turn if turn.completed?
      end
    end

    def subprocess(*args)
      output, error, status = Open3.capture3(RbConfig.ruby, __FILE__, *args)
      check(status.success?, "subprocess #{args.inspect}: #{error}")
      JSON.parse(output)
    end

    def submit(mode = nil)
      options = { "gate_reviews" => mode == "gated", "crash_after_publish" => mode == "crash" }
      run = TurnKit.resolve_agent("coordinator").run("Research the dossier and publish a reviewed report.", metadata: options, async: true).perform_later
      { turn_id: run.id, conversation_id: run.turn.conversation.id, submitter_pid: Process.pid }
    end

    def verify_report(id)
      turn = finished(id)
      check(Report.where(turn_uid: id).count == 1, "exactly one saved report")
      check(Report.find_by!(turn_uid: id).body == turn.output_text, "saved report matches final output")
      children = TurnKit::Run.new(turn).child_turn_records
      check(children.size == 2 && children.all? { |row| row['status'] == 'completed' }, "two successful reviews")
      results = turn.conversation.messages.select { |message| message.kind == "tool_result" }
      names = results.map { |message| message.metadata['tool_name'] }
      check(names == %w[read_research evidence_review risk_review save_report], "research → ordered review results → publication")
      { turn_id: id, conversation_id: turn.conversation.id, reports: 1, reviews: 2 }
    end

    def normal
      submitted = subprocess("submit", LIVE ? "live" : "gated")
      check(submitted.fetch("submitter_pid") != Process.pid, "submitter exited independently")
      id = submitted.fetch("turn_id")
      unless LIVE
        children = eventually("both reviewers running concurrently") do
          rows = TurnKit.store.list_turns(root_turn_id: id).reject { |row| row['id'] == id }
          rows if rows.size == 2 && Signal.where(turn_uid: rows.map { |row| row['id'] }, name: "review_started").count == 2
        end
        check(TurnKit.load_turn(id).waiting?, "parent releases worker while waiting")
        check(children.all? { |row| row['status'] == 'running' }, "both reviewers overlap")
        risk = children.find { |row| row['agent_name'] == 'risk_review' }
        Signal.where(turn_uid: risk.fetch('id')).update_all(released: true)
        finished(risk.fetch('id'))
        check(TurnKit.load_turn(id).waiting?, "parent cannot finish before remaining review")
        Signal.where(turn_uid: children.map { |row| row['id'] }).update_all(released: true)
      end
      verify_report(id).merge(parallel_barriers_verified: !LIVE)
    end

    def conversation
      first = TurnKit.resolve_agent("inbox").run("Remember project Cedar.", async: true).perform_later
      finished(first.id)
      response = subprocess("follow_up", first.turn.conversation.id)
      second = finished(response.fetch("turn_id"))
      check(second.conversation.id == first.turn.conversation.id, "reloaded same conversation")
      check(second.conversation.messages.any? { |message| message.text.include?("project Cedar") }, "history survived process exit")
      check(second.output_text.include?("Cedar"), "follow-up incorporates earlier context")
      { conversation_id: second.conversation.id, follow_up_turn: second.id }
    end

    def messaging
      check(!LIVE, "deterministic messaging barriers run in fake mode")
      source = TurnKit.resolve_agent("inbox").conversation
      destination = TurnKit.resolve_agent("inbox").conversation
      busy = destination.ask("hold", async: true).perform_later
      eventually("receiver blocked in model call") { Signal.find_by(turn_uid: busy.id, name: "busy") }
      key = "message:#{SecureRandom.uuid}"
      delivery = source.send_message(destination, "Cedar update", key: key)
      source.send_message(destination, "Cedar update", key: key)
      eventually("busy inbox delivery") { destination.inbox.first&.fetch("delivered_at") }
      check(destination.inbox.size == 1 && source.outbox.size == 1, "duplicate key delivers once")
      check(TurnKit.store.list_turns(conversation_id: destination.id).size == 1, "no competing turn while busy")
      Signal.where(turn_uid: busy.id).update_all(released: true)
      check(!finished(busy.id).output_text.include?("Cedar update"), "in-flight input snapshot unchanged")
      next_turn = eventually("automatic next turn") do
        TurnKit.store.list_turns(conversation_id: destination.id).find { |row| row['id'] != busy.id }
      end
      check(finished(next_turn.fetch('id')).output_text.include?("Cedar update"), "next turn consumes delivered message")
      source.send_message(destination, "idle wake", key: "idle:#{SecureRandom.uuid}")
      eventually("idle receiver wakes") do
        TurnKit.store.list_turns(conversation_id: destination.id).any? { |row| row['status'] == 'completed' && row['output_text'].include?('idle wake') }
      end
      callback = TurnKit.resolve_agent("inbox").conversation
      child = TurnKit.resolve_agent("inbox").run("Detached work", async: true).perform_later(callback: callback.id)
      finished(child.id)
      eventually("durable completion callback") { callback.inbox.first&.fetch("delivered_at") }
      callback_turn = eventually("callback wakes recipient") { TurnKit.store.list_turns(conversation_id: callback.id).first }
      finished(callback_turn.fetch('id'))
      check(callback.inbox.first.fetch('source_turn_id') == child.id, "callback identifies completed child")
      { delivery_id: delivery.fetch('id'), callback_turn: callback_turn.fetch('id') }
    end

    def recovery
      check(!LIVE, "fault injection is fake-mode only")
      id = subprocess("submit", "crash").fetch("turn_id")
      signal = eventually("worker killed after committed report") { Signal.find_by(turn_uid: id, name: "crashed_after_publish") }
      # Do not backdate heartbeats or execute the turn inline. The real recurring
      # job must find the expired claim and enqueue work for a replacement worker.
      result = verify_report(id)
      check(Signal.where(turn_uid: id, name: "crashed_after_publish").count == 1, "completed tool did not execute again")
      check(TurnKit.store.list_tool_executions(turn_id: id).count { |row| row['tool_name'] == 'save_report' } == 1, "one publication execution")
      result.merge(killed_worker_pid: signal.pid, recovery: "recurring reconciliation")
    end

    def media
      check(!LIVE || ENV['TURNKIT_DEMO_MEDIA'] == '1', "live media requires explicit TURNKIT_DEMO_MEDIA=1 in submitter and worker")
      parent = TurnKit.resolve_agent("inbox").conversation
      child = TurnKit.resolve_agent("media").run("Generate and inspect a report illustration", async: true).perform_later(callback: parent.id)
      turn = finished(child.id)
      execution = turn.tool_executions.find { |item| item.tool_name == 'prepare_image' }
      reference = execution.result.fetch('image_message_id')
      image_message = TurnKit.load_conversation(turn.conversation.id).messages.find { |message| message.id == reference }
      check(image_message&.image?, "image artifact reference resolves after reconstruction")
      check(turn.conversation.messages.any?(&:media_analysis?), "image was analyzed")
      eventually("media callback delivered") { parent.inbox.first&.fetch('delivered_at') }
      callback = JSON.parse(parent.inbox.first.fetch('payload').fetch('text'))
      check(JSON.parse(callback.fetch('result')).fetch('image_message_id') == reference, "parent receives artifact reference")
      recipient = eventually("media recipient woke") { TurnKit.store.list_turns(conversation_id: parent.id).first }
      finished(recipient.fetch('id'))
      { turn_id: child.id, image_message_id: reference, live: LIVE }
    end
  end
end

command = ARGV.shift || "all"
result = case command
when "submit" then DurableResearch::Scenarios.submit(ARGV.shift)
when "follow_up"
  conversation = TurnKit.load_conversation(ARGV.fetch(0))
  turn = conversation.ask("Which project did I ask you to remember?", async: true).perform_later
  { turn_id: turn.id }
when "verify" then DurableResearch::Scenarios.verify_report(ARGV.fetch(0))
when "all"
  abort "Use individual scenarios for paid live runs" if DurableResearch::LIVE
  %w[normal conversation messaging recovery media].to_h { |name| [name, DurableResearch::Scenarios.public_send(name)] }
when "normal", "conversation", "messaging", "recovery", "media"
  DurableResearch::Scenarios.public_send(command)
else abort "Usage: scenarios.rb [all|normal|conversation|messaging|recovery|media|submit|verify TURN_ID|follow_up CONVERSATION_ID]"
end
puts JSON.pretty_generate(result)
