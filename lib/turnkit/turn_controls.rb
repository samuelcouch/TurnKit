# frozen_string_literal: true

module TurnKit
  # Human controls share the execution root lock. Options are the durable
  # source of truth; no callbacks or job payloads are needed for recovery.
  module TurnControls
    def pause!(descendants: :retain, principal: nil)
      control_tree(:pause, descendants, principal) do |row|
        controls = row.dig("options", "controls") || {}
        attrs = { options: row.fetch("options").merge("controls" => controls.merge("pause_requested" => true)) }
        attrs[:status] = "paused" unless row["status"] == "running"
        @base_store.update_turn(row.fetch("id"), attrs)
      end
      reload
    end

    def resume!(descendants: :retain, principal: nil)
      control_tree(:resume, descendants, principal) do |row|
        controls = row.dig("options", "controls") || {}
        attrs = { options: row.fetch("options").merge("controls" => controls.merge("pause_requested" => false)) }
        if row["status"] == "paused"
          attrs[:status] = Background.ready?(@base_store, row.fetch("id")) ? "pending" : "waiting"
        end
        @base_store.update_turn(row.fetch("id"), attrs)
      end
      Background.enqueue if background?
      reload
    end

    def steer!(text, key:, principal: nil, descendants: :retain)
      raise ArgumentError, "key must be a nonempty string" unless key.is_a?(String) && !key.empty?
      text = text.to_s
      principal = JSON.parse(JSON.generate(principal))
      receipts = []
      control_tree(:steer, descendants, principal) do |row|
        controls = row.dig("options", "controls") || {}
        inputs = controls.fetch("inputs", [])
        existing = inputs.find { |input| input["key"] == key }
        if existing
          unless existing["text"] == text && existing["principal"] == principal
            raise ToolError, "steering key is already used for a different input"
          end
          receipts << existing
          next
        end
        if Background::TERMINAL.include?(row["status"]) || row["status"] == "stale"
          raise Error, "cannot steer a #{row['status']} turn; post next-turn input instead" if row["id"] == id
          next
        end
        input = { "id" => SecureRandom.uuid, "key" => key, "text" => text,
          "principal" => principal, "turn_id" => row.fetch("id"), "sequence" => inputs.length + 1 }
        @base_store.update_turn(row.fetch("id"), options: row.fetch("options").merge(
          "controls" => controls.merge("inputs" => inputs + [input])))
        receipts << input
      end
      receipts
    end

    def control_state(principal: nil)
      Authorization.authorize!(:read_control, principal: principal, turn: self)
      row = @base_store.load_turn(id)
      { "status" => row.fetch("status"), "controls" => row.dig("options", "controls") || {} }
    end

    # Called before dispatching another unit of work, never during a remote
    # call. The lock acquisition is the dispatch/control linearization point.
    def control_boundary!
      store.atomic do
        reload
        if @record.dig("options", "controls", "pause_requested")
          update!(status: "paused", claim_token: nil)
          next :paused
        end
        inputs = @record.dig("options", "controls", "inputs") || []
        pending = inputs.reject { |input| input["message_id"] }
        next unless pending.any?
        unless Background.ready?(store, id)
          next Background.deadline_exceeded?(store, @record) ? nil : :waiting
        end

        executions = store.list_tool_executions(turn_id: id)
        parts = @record.dig("options", "state", "parts") || []
        parts.select { |part| part["type"] == "tool_call" }.each do |part|
          execution = executions.find { |row| row["tool_call_id"] == part["id"] }
          child = store.list_turns(root_turn_id: root_turn_id).find { |row| execution && row["parent_tool_execution_id"] == execution["id"] }
          if child && Background::TERMINAL.include?(child["status"]) && %w[pending running].include?(execution["status"])
            store.claim_tool_execution(execution.fetch("id"), from: execution.fetch("status"), to: "completed",
              result: SubAgentTool.result(child), completed_at: Clock.now)
          elsif !execution
            store.create_tool_execution("turn_id" => id, "tool_call_id" => part.fetch("id"), "tool_name" => part.fetch("name"),
              "arguments" => part["arguments"], "status" => "cancelled", "completed_at" => Clock.now,
              "result" => { "skipped" => true, "message" => "not executed: superseded by human steering" })
          end
        end
        executions = Reconciliation.interrupt_tool_executions(@record, store: store)
        # Complete known results and close unexecuted proposals before adding
        # human input: providers require a result for every assistant tool ID.
        Reconciliation.repair_transcript(@record, executions, store: store)
        pending.each do |input|
          message = conversation.append_message(role: "user", kind: "text", text: input.fetch("text"), turn_id: id,
            metadata: { "steering_id" => input.fetch("id"), "principal" => input["principal"] })
          input["message_id"] = message.id
        end
        options = @record.fetch("options")
        update!(options: options.merge("controls" => options.fetch("controls").merge("inputs" => inputs)))
        update_state!("phase" => "model", "parts" => nil, "candidate" => nil, "output_data" => nil, "terminal_tool_name" => nil)
        :steered
      end
    end

    private
      def control_tree(action, descendants, principal)
        raise ArgumentError, "descendants must be :retain or :cascade" unless %i[retain cascade].include?(descendants)
        @base_store.atomic(Background.root_conversation(@base_store, @record)) do
          rows = [@base_store.load_turn(id)]
          if descendants == :cascade
            all = @base_store.list_turns(root_turn_id: root_turn_id)
            loop do
              ids = rows.map { |row| row.fetch("id") }
              added = all.select { |row| ids.include?(row["parent_turn_id"]) && !ids.include?(row["id"]) }
              break if added.empty?
              rows.concat(added)
            end
          end
          rows.each do |row|
            Authorization.authorize!(action, principal: principal,
              turn: row["id"] == id ? self : Background.load_turn(row.fetch("id"), store: @base_store), descendants: descendants)
          end
          rows.each do |row|
            next if action != :steer && (Background::TERMINAL.include?(row["status"]) || row["status"] == "stale")
            yield row
          end
        end
      end
  end
end
