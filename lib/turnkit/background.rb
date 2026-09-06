# frozen_string_literal: true

module TurnKit
  # Jobs are wake-up signals. Submitted turns, deliveries, and waits in the
  # store are authoritative and can be rediscovered after a lost enqueue.
  module Background
    TERMINAL = %w[completed failed cancelled].freeze
    module_function

    def root_conversation(store, record)
      store.load_turn(record.fetch("root_turn_id")).fetch("conversation_id")
    end

    def load_turn(id, store: TurnKit.store)
      record = store.load_turn(id)
      agent = TurnKit.resolve_agent(record.fetch("agent_name"))
      conversation = load_conversation(record.fetch("conversation_id"), store: store, agent: agent)
      depth = 0
      ancestor = record
      while ancestor["parent_turn_id"]
        depth += 1
        ancestor = store.load_turn(ancestor.fetch("parent_turn_id"))
      end
      Turn.new(agent: agent, conversation: conversation, record: record, store: store, depth: depth)
    end

    def load_conversation(id, store: TurnKit.store, agent: nil)
      record = store.load_conversation(id)
      agent ||= TurnKit.resolve_agent(record.fetch("agent_name"))
      Conversation.new(agent: agent, record: record, store: store, model: record["model"], subject: record["subject"], metadata: record["metadata"])
    end

    def submit(turn, callback: nil)
      store = turn.store
      raw = store
      raw = raw.__getobj__ while raw.is_a?(ExecutionStore)
      raise ConfigError, "background turns must use TurnKit.store" unless raw.equal?(TurnKit.store)
      TurnKit.resolve_agent(turn.agent_name)
      principal = store.load_turn(turn.id).dig("options", "principal")
      Authorization.authorize!(:callback, principal: principal, turn: turn.id, destination_conversation: callback) if callback
      store.load_conversation(callback) if callback
      store.atomic(root_conversation(store, store.load_turn(turn.id))) do
        record = store.load_turn(turn.id)
        raise Error, "only pending turns can be submitted" unless record["status"] == "pending"
        options = record.fetch("options")
        options = options.merge("callback_conversation_id" => callback) if callback
        store.update_turn(turn.id, submitted_at: record["submitted_at"] || Clock.now, options: options,
          status: ready?(store, turn.id) ? "pending" : "waiting")
      end
      enqueue(turn.id)
      turn.reload
    end

    def enqueue(id = nil)
      if TurnKit.store.is_a?(ActiveRecordStore)
        require_relative "job"
        ActiveRecord.after_all_transactions_commit { dispatch_job(id) }
      else
        dispatch_job(id)
      end
    end

    def dispatch_job(id)
      if TurnKit.job_dispatcher
        TurnKit.job_dispatcher.call(id)
      else
        raise ConfigError, "background jobs require ActiveRecordStore" unless TurnKit.store.is_a?(ActiveRecordStore)
        require_relative "job"
        if [ActiveJob::QueueAdapters::InlineAdapter, ActiveJob::QueueAdapters::AsyncAdapter].any? { |type| Job.queue_adapter.is_a?(type) }
          raise ConfigError, "configure a persistent Active Job backend (not inline or async)"
        end
        Job.perform_later(id)
      end
    end

    def perform(id = nil)
      if id
        turn = load_turn(id)
        turn.run! if turn.background?
      end
      drain
    end

    def claim(store, record)
      store.atomic(root_conversation(store, record)) do
        store.atomic(record.fetch("conversation_id")) do
          current = store.load_turn(record.fetch("id"))
          next unless current["status"] == "pending"
          state = current.dig("options", "state") || {}
          next if !state["phase"] && !ready?(store, current.fetch("id")) && !deadline_exceeded?(store, current)
          if current["submitted_at"]
            others = store.list_turns(conversation_id: current.fetch("conversation_id")).reject { |row| row["id"] == current["id"] }
            next if others.any? { |row| %w[running waiting].include?(row["status"]) }
            first = ([current] + others.select { |row| row["submitted_at"] && row["status"] == "pending" }).min_by { |row| [row["created_at"], row["id"]] }
            next unless first["id"] == current["id"]
          end
          # An application-level join supplies its results as turn-local input.
          # Tool-level joins already have a persisted tools phase/result channel.
          waits = store.list_waits(turn_id: current.fetch("id"))
          if waits.any? && !state["phase"] && !state["wait_input"] && ready?(store, current.fetch("id"))
            results = waits.map { |wait| SubAgentTool.result(store.load_turn(wait.fetch("target_turn_id"))) }
            store.append_message("conversation_id" => current.fetch("conversation_id"), "turn_id" => current.fetch("id"),
              "role" => "user", "kind" => "text", "text" => { "wait_results" => results }.to_json)
            current = store.update_turn(current.fetch("id"), options: current.fetch("options").merge("state" => state.merge("wait_input" => true)))
          end
          store.claim_turn(current.fetch("id"), started_at: current["started_at"] || Clock.now, heartbeat_at: Clock.now, claim_token: SecureRandom.hex(16))
        end
      end
    end

    def send_message(source:, destination:, text:, key:, store: TurnKit.store, source_turn_id: nil, principal: nil)
      Authorization.authorize!(:send_message, principal: principal, source_conversation: source, destination_conversation: destination)
      store.load_conversation(destination)
      delivery = store.create_delivery(
        "source_conversation_id" => source, "destination_conversation_id" => destination,
        "source_turn_id" => source_turn_id, "key" => key, "payload" => { "text" => text }
      )
      enqueue
      delivery
    end

    def callback(store, record)
      destination = record.dig("options", "callback_conversation_id")
      return unless destination && TERMINAL.include?(record["status"])

      Authorization.authorize!(:callback, principal: record.dig("options", "principal"), turn: record.fetch("id"), destination_conversation: destination)

      store.create_delivery(
        "source_conversation_id" => record.fetch("conversation_id"), "destination_conversation_id" => destination,
        "source_turn_id" => record.fetch("id"), "key" => "completion:#{record.fetch('id')}",
        "payload" => { "text" => SubAgentTool.result(record).to_json }
      )
    end

    def callback_after_terminal(store, record)
      callback(store, record)
    rescue AuthorizationError => error
      options = record.fetch("options").merge("callback_denied" => {
        "class" => error.class.name, "message" => error.message, "at" => Clock.now.iso8601
      })
      store.update_turn(record.fetch("id"), options: options)
    end

    def deliver(delivery, store: TurnKit.store)
      destination = delivery.fetch("destination_conversation_id")
      store.atomic(destination) do
        delivery = store.load_delivery(delivery.fetch("id"))
        next if delivery["delivered_at"]

        message = store.append_message(
          "conversation_id" => destination, "role" => "user", "kind" => "text",
          "text" => delivery.fetch("payload").fetch("text"),
          "metadata" => { "delivery_id" => delivery.fetch("id"), "source_conversation_id" => delivery["source_conversation_id"], "source_turn_id" => delivery["source_turn_id"] }
        )
        store.update_delivery(delivery.fetch("id"), message_id: message.fetch("id"), delivered_at: Clock.now)
        wake(destination, store: store)
      end
    end

    def wake(conversation_id, store: TurnKit.store)
      store.atomic(conversation_id) do
        next if store.busy_conversation?(conversation_id)
        incoming = store.next_delivery_trigger(conversation_id)
        next unless incoming

        conversation = load_conversation(conversation_id, store: store)
        turn = conversation.build_turn(trigger_message_id: incoming.fetch("id"), principal: conversation.metadata["principal"])
        store.update_turn(turn.id, submitted_at: Clock.now)
      end
    end

    def wait(turn, targets, transition: false)
      ids = Array(targets).map { |target| target.respond_to?(:id) ? target.id : target.to_s }.uniq
      principal = turn.store.load_turn(turn.id).dig("options", "principal")
      Authorization.authorize!(:wait, principal: principal, turn: turn.id, targets: ids)
      turn.store.atomic_graph do
        turn.store.atomic(root_conversation(turn.store, turn.store.load_turn(turn.id))) do
          current = turn.store.load_turn(turn.id)
          raise Error, "only pending turns can wait" if transition && current["status"] != "pending"
          ids.each do |id|
            raise ToolError, "a turn cannot wait for itself" if id == turn.id
            target = turn.store.load_turn(id)
            raise ToolError, "wait targets must be submitted" unless target["submitted_at"] || TERMINAL.include?(target["status"])
            if target["conversation_id"] == turn.conversation.id && !TERMINAL.include?(target["status"])
              raise ToolError, "cannot wait for unfinished work in the same conversation"
            end
            raise ToolError, "wait would create a cycle" if wait_reachable?(turn.store, id, turn.id)
            turn.store.create_wait(turn_id: turn.id, target_turn_id: id)
          end
          turn.store.update_turn(turn.id, status: "waiting") if transition && current["submitted_at"] && !ready?(turn.store, turn.id)
        end
      end
      ids
    end

    def wait_reachable?(store, from, sought, seen = {})
      target = store.load_turn(from)
      return false if TERMINAL.include?(target["status"])
      conversation = target.fetch("conversation_id")
      return true if conversation == store.load_turn(sought).fetch("conversation_id")
      return false if seen[conversation]
      seen[conversation] = true
      # A conversation is a serial execution lane. Conservatively include waits
      # of every unfinished peer, not just explicit edges on the requested turn.
      store.list_turns(conversation_id: conversation).reject { |row| TERMINAL.include?(row["status"]) }.any? do |row|
        store.list_waits(turn_id: row.fetch("id")).any? { |edge| wait_reachable?(store, edge.fetch("target_turn_id"), sought, seen) }
      end
    end

    def ready?(store, id)
      store.list_waits(turn_id: id).all? { |wait| TERMINAL.include?(store.load_turn(wait.fetch("target_turn_id"))["status"]) }
    end

    def deadline_exceeded?(store, record)
      root = store.load_turn(record.fetch("root_turn_id"))
      limits = root.dig("options", "budget_limits") || {}
      timeout = limits.fetch("timeout", TurnKit.timeout)
      start = root["submitted_at"] || root["started_at"]
      timeout && start && Clock.now >= start + timeout
    end

    def drain(store: TurnKit.store)
      limit = TurnKit.maintenance_batch_size
      store.list_deliveries(pending: true, limit: limit).each { |delivery| deliver(delivery, store: store) }
      turns = store.list_actionable_turns(limit: limit)
      turns.each do |record|
        if record["status"] == "waiting"
          store.atomic(root_conversation(store, record)) do
            current = store.load_turn(record.fetch("id"))
            next unless current["status"] == "waiting"
            if ready?(store, current.fetch("id")) || deadline_exceeded?(store, current)
              store.claim_turn(current.fetch("id"), from: "waiting", to: "pending")
            else
              store.claim_turn(current.fetch("id"), from: "waiting", to: "waiting") # rotate safely
            end
          end
        elsif record["status"] == "running"
          store.claim_turn(record.fetch("id"), from: "running", to: "running") # rotate without changing heartbeat
        elsif record["status"] == "pending"
          store.claim_turn(record.fetch("id"), from: "pending", to: "pending") # blocked conversations must rotate too
        end
      end
      turns.group_by { |record| record.fetch("conversation_id") }.each do |conversation_id, records|
        next if store.busy_conversation?(conversation_id, include_pending: false)
        record = records.find { |row| row["status"] == "pending" }
        if record
          rotated = store.claim_turn(record.fetch("id"), from: "pending", to: "pending")
          enqueue(record.fetch("id")) if rotated
        end
      end
    end

    def reconcile(before: Clock.now - (TurnKit.timeout || 300), store: TurnKit.store)
      store.list_actionable_turns(limit: TurnKit.maintenance_batch_size).each do |record|
        store.atomic(root_conversation(store, record)) do
          record = store.load_turn(record.fetch("id"))
          next unless record["status"] == "running" && record.fetch("heartbeat_at") < before

          store.update_turn(record.fetch("id"), claim_token: nil)
          # A pending child is known work, not an interrupted external effect.
          executions = store.list_tool_executions(turn_id: record.fetch("id"))
          executions.each do |execution|
            next unless execution["status"] == "running"
            loaded = Background.load_turn(record.fetch("id"), store: store)
            tool = loaded.agent.effective_tools(turn: loaded).find { |candidate| candidate.tool_name == execution["tool_name"] }
            recovery = tool.is_a?(Class) ? tool.recovery : tool&.class&.recovery
            ordinary = tool && !(tool.is_a?(Class) && tool < SubAgentTool) &&
              ![WaitTool, LaunchAgentTool, SendMessageTool].include?(tool)
            if ordinary && recovery == :replay_safe
              store.claim_tool_execution(execution.fetch("id"), to: "pending", started_at: nil)
              next
            end
            store.claim_tool_execution(execution.fetch("id"), to: "interrupted", error: { "message" => Reconciliation::INTERRUPTED_MESSAGE }, completed_at: Clock.now)
          end
          store.update_turn(record.fetch("id"), status: "pending", heartbeat_at: nil)
        end
      end
      drain(store: store)
    end
  end
end
