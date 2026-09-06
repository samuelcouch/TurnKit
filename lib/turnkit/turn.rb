# frozen_string_literal: true

module TurnKit
  class Turn
    STATUSES = Record::TURN_STATUSES

    attr_reader :agent, :conversation, :store, :budget, :depth
    attr_reader :id, :conversation_id, :agent_name, :parent_turn_id, :parent_tool_execution_id
    attr_reader :root_turn_id, :context_message_sequence, :model, :thinking, :compact, :output_schema, :prompt_mode
    attr_reader :started_at

    def initialize(agent:, conversation:, record:, store:, budget: nil, depth: 0, on_event: nil)
      @agent = agent
      @conversation = conversation
      @store = store
      @base_store = store
      @record = record.transform_keys(&:to_s)
      @id = @record.fetch("id")
      @conversation_id = @record.fetch("conversation_id")
      @agent_name = @record["agent_name"]
      @parent_turn_id = @record["parent_turn_id"]
      @parent_tool_execution_id = @record["parent_tool_execution_id"]
      @root_turn_id = @record["root_turn_id"] || id
      @context_message_sequence = @record["context_message_sequence"].to_i
      @model = @record["model"] || agent.effective_model
      @thinking = thinking_from_options
      @compact = compact_from_options
      @output_schema = output_schema_from_options
      @prompt_mode = prompt_mode_from_options
      @started_at = @record["started_at"]
      @budget = budget || agent.build_budget
      @depth = depth
      @on_event = on_event
    end

    def run!(&block)
      @on_event = block if block
      return self unless status == "pending"

      @store = @base_store
      claimed = Background.claim(store, @record)
      return self unless claimed

      @record = claimed
      @started_at = @record["started_at"]
      fence!
      with_heartbeat do
        emit("turn.started", status: status, model: model)
        agent.effective_client.validate!(model: model)
        execute
      end
      reload
      self
    rescue LostClaim
      reload
    rescue StandardError => error
      # Background infrastructure failures must reach the job backend. The
      # reconciler recovers the persisted phase rather than guessing here.
      raise if background? && !error.is_a?(TurnKit::Error)
      raise unless claimed

      update!(status: "failed", error: { "class" => error.class.name, "message" => error.message }, completed_at: Clock.now)
      emit("turn.failed", error: { "class" => error.class.name, "message" => error.message })
      reload
      self
    end

    def background? = !!@record["submitted_at"]

    def perform_later(callback: nil)
      Background.submit(self, callback: callback.respond_to?(:id) ? callback.id : callback)
    end

    def wait_for(*targets)
      Background.wait(self, targets.flatten, transition: true)
      reload
    end

    def suspend!
      update!(status: "waiting", claim_token: nil)
    end

    # Revokes the local claim. An already-sent remote request cannot be
    # recalled, but ExecutionStore fences every later write from that worker.
    def cancel!(descendants: :retain, principal: nil)
      raise ArgumentError, "descendants must be :retain or :cascade" unless %i[retain cascade].include?(descendants)
      Authorization.authorize!(:cancel, principal: principal, turn: self, descendants: descendants)
      @base_store.atomic(Background.root_conversation(@base_store, @record)) do
        all = @base_store.list_turns(root_turn_id: root_turn_id)
        rows = [@base_store.load_turn(id)]
        if descendants == :cascade
          descendant_ids = { id => true }
          loop do
            added = all.select { |row| row["parent_turn_id"] && descendant_ids[row["parent_turn_id"]] && !descendant_ids[row["id"]] }
            break if added.empty?
            added.each { |row| descendant_ids[row["id"]] = true }
          end
          rows.concat(all.select { |row| row["id"] != id && descendant_ids[row["id"]] })
        end
        rows.each do |row|
          next if Background::TERMINAL.include?(row["status"])
          executions = Reconciliation.interrupt_tool_executions(row, store: @base_store)
          Reconciliation.repair_transcript(row, executions, store: @base_store)
          attrs = { status: "cancelled", claim_token: nil, completed_at: Clock.now,
            error: { "class" => "TurnKit::Cancelled", "message" => "cancelled by application" } }
          terminal_row = @base_store.update_turn(row.fetch("id"), attrs)
          Background.callback_after_terminal(@base_store, terminal_row) if row["submitted_at"]
        end
        rows.map { |row| row.fetch("conversation_id") }.uniq.each { |conversation_id| Background.wake(conversation_id, store: @base_store) } if background?
      end
      Background.enqueue if background?
      reload
    end

    def execution_budget(excluding: nil)
      root = store.load_turn(root_turn_id)
      limits = root.dig("options", "budget_limits") || agent.budget_limits
      turns = store.list_turns(root_turn_id: root_turn_id)
      executions = turns.flat_map { |row| store.list_tool_executions(turn_id: row.fetch("id")) }.reject { |row| row["id"] == excluding }
      Budget.new(**limits.transform_keys(&:to_sym), root_started_at: root["submitted_at"] || root["started_at"] || Clock.now).seed!(turns: turns, tool_executions: executions)
    end

    def preview
      model_request
    end

    def status
      @record.fetch("status")
    end

    STATUSES.each do |state|
      define_method("#{state}?") { status == state }
    end

    def output_text
      @record["output_text"].to_s
    end

    def output_data
      @record["output_data"]
    end

    def context = JSON.parse(JSON.generate(@record.dig("options", "context") || {}))

    def policy_audit
      options = @record["options"] || {}
      options.dig("state", "policy_audit") || options["policy_audit"]
    end

    # Reads iterations from options["state"], falling back to the legacy
    # top-level key for turns persisted before the state split.
    def self.iterations_for(record)
      options = record["options"] || {}
      (options.dig("state", "iterations") || options["iterations"]).to_i
    end

    def usage
      Usage.from_h(@record["usage"] || {})
    end

    def cost
      Cost.from_record(@record)
    end

    def tool_executions
      store.list_tool_executions(turn_id: id).map { |attrs| ToolExecution.new(attrs) }
    end

    def reload
      @record = store.load_turn(id)
      @thinking = thinking_from_options
      @compact = compact_from_options
      @output_schema = output_schema_from_options
      @prompt_mode = prompt_mode_from_options
      self
    end

    def stale!
      update!(status: "stale", completed_at: Clock.now)
    end

    def emit(type, payload = {})
      emit_event(Event.new(type: type, turn_id: id, conversation_id: conversation.id, payload: payload))
    end

    def internal_model_call(model:, messages:, instructions:, tools: [], thinking: nil, output_schema: nil, metadata: {}, purpose:, client: nil)
      request = ModelRequest.new(
        model: model,
        messages: messages,
        tools: tools,
        instructions: instructions,
        thinking: thinking,
        output_schema: output_schema,
        metadata: { purpose: purpose.to_s, turn_id: id, conversation_id: conversation.id }.merge(metadata || {})
      )
      model_client = client || agent.effective_client
      model_client.validate!(model: request.model)

      emit_model_requested("#{purpose}.model.requested", request)
      result = call_client(request, client: model_client)
      result_cost = Cost.from_usage(result.usage, model: result.model || request.model)
      add_usage!(result.usage, cost: result_cost)
      emit_model_completed("#{purpose}.model.completed", result, result_cost, model: request.model)
      budget.add_cost!(result_cost.total)
      result
    end

    def paint(prompt, model:, provider: nil, size: nil, assume_model_exists: nil, input_images: nil, mask: nil, params: {}, metadata: {}, client: nil)
      claimed = claim_standalone!("paint")
      if claimed
        @record = claimed
        @started_at = @record["started_at"]
        fence!
        emit("turn.started", status: status, model: model)
        @budget = Budget.resume(store: store, root_turn_id: root_turn_id, limits: agent.budget_limits)
      end
      image_client = client || agent.effective_client
      request = {
        prompt: prompt,
        model: model,
        provider: provider,
        size: size,
        assume_model_exists: assume_model_exists,
        input_images: input_images,
        mask: mask,
        params: params || {},
        metadata: { turn_id: id, conversation_id: conversation.id }.merge(metadata || {})
      }

      image_client.validate!(model: model)
      emit("image.requested", request.except(:input_images, :mask))
      result = call_image_client(image_client, request)
      result_cost = apply_result_cost(result, model: model)
      image = result.images.first
      raise Error, "image client returned no image" unless image
      raise Error, "image client returned image without url or data" if image.url.to_s.empty? && image.data.to_s.empty?

      persist_image_message(image)
      emit("image.completed", image: image.to_h, model: image.model || model, provider: image.provider || provider&.to_s, mime_type: image.mime_type, usage: result.usage.to_h, cost: result_cost.to_h, metadata: metadata || {})
      complete_with_output(image.url.to_s, output_data: { "type" => "image", "images" => [ image.to_h ] }, audit: check_policy(image.url.to_s, output_data: { "type" => "image", "images" => [ image.to_h ] })) if claimed
      image
    rescue StandardError => error
      fail_standalone!(error) if claimed
      raise
    end

    def view_media(media, objective:, model:, provider: nil, output_schema: nil, params: {}, metadata: {}, client: nil)
      claimed = claim_standalone!("view media")
      if claimed
        @record = claimed
        @started_at = @record["started_at"]
        fence!
        emit("turn.started", status: status, model: model)
        @budget = Budget.resume(store: store, root_turn_id: root_turn_id, limits: agent.budget_limits)
      end
      media_input = MediaInput.wrap(media)
      media_client = client || agent.effective_client
      request = {
        media: media_input,
        objective: objective,
        model: model,
        provider: provider,
        output_schema: output_schema,
        params: params || {},
        metadata: { turn_id: id, conversation_id: conversation.id }.merge(metadata || {})
      }

      media_client.validate!(model: model)
      emit("media.requested", request.except(:media).merge(media: media_input.to_h))
      result = call_media_client(media_client, request)
      result_cost = apply_result_cost(result, model: model)
      analysis = result.media_analyses.first
      raise Error, "media client returned no media analysis" unless analysis

      persist_media_analysis_message(analysis)
      output_data = { "type" => "media_analysis", "media_analyses" => [ analysis.to_h ] }
      emit("media.completed", analysis: analysis.to_h, model: analysis.model || model, provider: analysis.provider || provider&.to_s, media: media_input.to_h, usage: result.usage.to_h, cost: result_cost.to_h, metadata: metadata || {})
      complete_with_output(analysis.text, output_data: output_data, audit: check_policy(analysis.text, output_data: output_data)) if claimed
      analysis
    rescue StandardError => error
      emit("media.failed", error: { "class" => error.class.name, "message" => error.message }, metadata: metadata || {}) if status == "running" || claimed
      fail_standalone!(error) if claimed
      raise
    end

    private
      def fence!
        @store = ExecutionStore.new(store, turn_id: id, token: @record.fetch("claim_token"), conversation_id: Background.root_conversation(store, @record))
        @conversation = Conversation.new(agent: agent, record: store.load_conversation(conversation.id), store: store,
          model: conversation.model, subject: conversation.subject, metadata: conversation.metadata)
      end

      def execute
        loop do
          @budget = execution_budget
          budget.check!(depth: depth)
          state = @record.dig("options", "state") || {}
          case state["phase"] || "model"
          when "model"
            count_iteration!
            TurnKit::Compaction.maybe_compact!(self)
            request = model_request
            emit_model_requested("model.requested", request)
            result = call_client(request)
            cost = Cost.from_usage(result.usage, model: result.model || model)
            store.atomic do
              add_usage!(result.usage, cost: cost)
              persist_assistant_message(result)
              update_state!("phase" => result.tool_calls? ? "tools" : "output", "parts" => result.parts,
                "candidate" => result.text, "output_data" => result.output_data, "terminal_tool_name" => nil)
            end
            emit_model_completed("model.completed", result, cost, model: model)
            budget.add_cost!(cost.total)
          when "tools"
            runner = ToolRunner.new(self)
            terminal = runner.dispatch(Result.new(parts: state.fetch("parts")).tool_calls)
            if terminal == :waiting
              suspend!
              break
            end
            store.atomic do
              if terminal
                candidate = append_terminal_completion(runner, terminal)
                update_state!("phase" => "output", "candidate" => candidate, "terminal_tool_name" => terminal.tool_name)
              else
                update_state!("phase" => "model", "parts" => nil)
              end
            end
          when "output"
            candidate = state.fetch("candidate")
            audit = check_policy(candidate, output_data: state["output_data"])
            revisions_used = state["revisions_used"].to_i
            if should_revise?(audit, revisions_used)
              store.atomic do
                append_revision_message(audit, attempt: revisions_used + 1, terminal_tool_name: state["terminal_tool_name"])
                update_state!("phase" => "model", "parts" => nil, "revisions_used" => revisions_used + 1)
              end
              emit("output_policy.revision", violation_count: audit.violations.length, attempt: revisions_used + 1)
            else
              complete_with_output(candidate, output_data: state["output_data"], audit: audit)
              break
            end
          end
        end
      end

      def with_heartbeat
        mutex, wake = Mutex.new, ConditionVariable.new
        stopped = false
        heartbeat = Thread.new do
          loop do
            break if mutex.synchronize {
              wake.wait(mutex, (TurnKit.timeout || 300) / 3.0) unless stopped
              stopped
            }
            heartbeat!
          end
        rescue LostClaim
          # The executing thread observes the same revocation on its next write.
        end
        yield
      ensure
        # Never interrupt a database write/connection initialization mid-flight.
        mutex.synchronize { stopped = true; wake.signal }
        heartbeat&.value
      end

      def model_request
        prompt = SystemPrompt.new(agent: agent, turn: self, conversation: conversation, mode: prompt_mode || agent.effective_prompt_mode(turn: self))
        instructions, dynamic_instructions = case agent.system_prompt
        when nil
          [ prompt.stable, prompt.dynamic ]
        when String
          [ agent.system_prompt, nil ]
        else
          [ agent.system_prompt.call(prompt).to_s, nil ]
        end
        ModelRequest.new(
          model: model,
          messages: llm_messages,
          tools: agent.effective_tools(turn: self),
          instructions: instructions,
          dynamic_instructions: dynamic_instructions,
          thinking: thinking,
          output_schema: output_schema,
          metadata: { turn_id: id, conversation_id: conversation.id },
          report: prompt.report
        )
      end

      # Clients implement the TurnKit::Client keyword contract. See client.rb.
      def call_client(request, client: agent.effective_client)
        client.chat(
          model: request.model,
          messages: request.messages,
          tools: request.tools,
          instructions: request.instructions,
          dynamic_instructions: request.dynamic_instructions,
          thinking: request.thinking,
          output_schema: request.output_schema,
          metadata: request.metadata,
          on_event: ->(event) { emit_event(event) }
        )
      end

      def call_image_client(client, request)
        with_heartbeat { client.paint(**request, on_event: ->(event) { emit_event(event) }) }
      end

      def call_media_client(client, request)
        with_heartbeat { client.view_media(**request, on_event: ->(event) { emit_event(event) }) }
      end

      def llm_messages
        MessageProjection.for(TurnKit::Compaction.project(conversation.messages_for_turn(self)))
      end

      def emit_model_requested(type, request)
        emit(
          type,
          model: request.model,
          tool_names: request.tool_names,
          message_count: request.messages.length,
          prompt: request.report
        )
      end

      def emit_model_completed(type, result, cost, model: self.model)
        emit(
          type,
          model: result.model || model,
          tool_call_count: result.tool_calls.length,
          usage: result.usage.to_h,
          cost: cost.to_h
        )
      end

      def thinking_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        return Agent.normalize_thinking(options["thinking"]) if options.key?("thinking")

        agent.effective_thinking
      end

      def compact_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["compact"] if options.key?("compact")
      end

      def output_schema_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["output_schema"] if options.key?("output_schema")
      end

      def prompt_mode_from_options
        options = (@record["options"] || {}).transform_keys(&:to_s)
        options["prompt_mode"]&.to_sym if options.key?("prompt_mode")
      end

      def persist_assistant_message(result)
        if result.tool_calls?
          message = conversation.append_message(
            role: "assistant",
            kind: "tool_call",
            content: result.parts,
            turn_id: id,
            metadata: {}
          )
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
          result.tool_calls.each { |call| emit("tool_call.created", id: call.id, name: call.name) }
        elsif result.image?
          message = conversation.append_message(role: "assistant", kind: "image", content: result.images.map { |image| image.to_h.merge("type" => "image") }, turn_id: id, metadata: { "output_data" => result.output_data }.compact)
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
        elsif result.media_analysis?
          message = conversation.append_message(role: "assistant", kind: "media_analysis", content: result.media_analyses.map { |analysis| analysis.to_h.merge("type" => "media_analysis") }, turn_id: id, metadata: { "output_data" => result.output_data }.compact)
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
        else
          message = conversation.append_message(role: "assistant", kind: "text", text: result.text, turn_id: id, metadata: { "output_data" => result.output_data }.compact)
          emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
        end
      end

      def persist_image_message(image)
        message = conversation.append_message(role: "assistant", kind: "image", content: [ image.to_h.merge("type" => "image") ], turn_id: id, metadata: { "output_data" => { "type" => "image", "images" => [ image.to_h ] } })
        emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def persist_media_analysis_message(analysis)
        message = conversation.append_message(role: "assistant", kind: "media_analysis", content: [ analysis.to_h.merge("type" => "media_analysis") ], turn_id: id, metadata: { "output_data" => { "type" => "media_analysis", "media_analyses" => [ analysis.to_h ] } })
        emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def append_terminal_completion(runner, execution)
        message = runner.completion_message(execution)
        assistant = conversation.append_message(role: "assistant", kind: "text", text: message, turn_id: id)
        emit("message.created", message_id: assistant.id, role: assistant.role, kind: assistant.kind)
        message
      end

      def complete_with_output(text, output_data: nil, audit: nil)
        attrs = { output_text: text, output_data: output_data, completed_at: Clock.now }
        if audit && !audit.clean? && agent.output_policy_mode == :fail
          attrs[:status] = "failed"
          attrs[:error] = { "class" => "TurnKit::OutputAudit", "message" => audit.messages.join("; "), "policy_audit" => audit.to_h }
        else
          attrs[:status] = "completed"
        end
        store.atomic(Background.root_conversation(store, @record)) do
          update_state!("policy_audit" => audit.to_h) if audit
          update!(attrs)
        end
        emit("output_policy.completed", clean: audit.clean?, violation_count: audit.violations.length) if audit

        if failed?
          emit("turn.failed", error: @record["error"])
        else
          emit("turn.completed", status: status, output_text: text)
        end
      end

      def check_policy(text, output_data: nil)
        constraints = agent.effective_output_policy
        return nil if constraints.empty?

        output = output_data.nil? ? text : output_data
        TurnKit.check_output_policy(output, constraints: constraints, context: { turn: self, output_text: text, output_data: output_data })
      end

      def should_revise?(audit, revisions_used)
        audit && !audit.clean? && revisions_used < agent.output_retries
      end

      def append_revision_message(audit, attempt:, terminal_tool_name: nil)
        text = <<~TEXT.strip
          The previous output failed policy checks.

          Revise the previous output. Do not introduce new claims.
          Do not deviate from the skill or policy below.

          #{revision_policy_blocks}

          Violations:
          #{audit.violations.each_with_index.map { |violation, index| "#{index + 1}. #{violation.rule}: #{violation.message}" }.join("\n")}
          #{terminal_tool_name ? "\nResubmit via #{terminal_tool_name}." : ""}
        TEXT
        message = conversation.append_message(role: "user", kind: "text", text: text, turn_id: id, metadata: { "source" => "output_policy", "attempt" => attempt })
        emit("message.created", message_id: message.id, role: message.role, kind: message.kind)
      end

      def revision_policy_blocks
        agent.effective_output_policy.filter_map do |policy|
          next unless policy.respond_to?(:content)

          key = policy.respond_to?(:name) ? policy.name : "output_policy"
          "<skill key=\"#{key}\">\n#{policy.content}\n</skill>"
        end.join("\n\n")
      end

      def add_usage!(usage, cost: nil)
        current = @record["usage"] || {}
        totals = {
          "input_tokens" => current["input_tokens"].to_i + usage.input_tokens,
          "output_tokens" => current["output_tokens"].to_i + usage.output_tokens,
          "cached_tokens" => current["cached_tokens"].to_i + usage.cached_tokens,
          "cache_write_tokens" => current["cache_write_tokens"].to_i + usage.cache_write_tokens,
          "thinking_tokens" => current["thinking_tokens"].to_i + usage.thinking_tokens,
          "total_tokens" => current["total_tokens"].to_i + usage.total_tokens
        }
        totals["cost_details"] = aggregate_cost(current["cost_details"], cost).to_h if cost&.total
        attributes = { usage: totals, heartbeat_at: Clock.now }
        attributes[:cost] = @record["cost"].to_f + cost.total if cost&.total
        update!(attributes)
      end

      def count_iteration!
        store.atomic do
          @budget = execution_budget
          budget.count_iteration!
          update_state!("iterations" => Turn.iterations_for(@record) + 1)
        end
      end

      # Runtime state lives under options["state"]; the rest of options is
      # write-once turn configuration. Reads fall back to the legacy top-level
      # keys for turns persisted before the split.
      def update_state!(changes)
        options = @record["options"] || {}
        update!(options: options.merge("state" => (options["state"] || {}).merge(changes)))
      end

      def heartbeat!
        store.update_turn(id, heartbeat_at: Clock.now)
      end

      # Claims a pending turn for a standalone media call. Returns the claimed
      # record when this call owns turn completion, nil when running inside a parent
      # turn (media tools call paint/view_media while their turn is running).
      # Callers perform any post-claim setup after assignment, so later errors
      # still fail the claimed turn.
      def claim_standalone!(action)
        case status
        when "pending"
          claimed = Background.claim(store, @record)
          raise Error, "turn is already running" unless claimed

          claimed
        when "running"
          nil
        else
          raise Error, "cannot #{action} for #{status} turn"
        end
      end

      def fail_standalone!(error)
        update!(status: "failed", error: { "class" => error.class.name, "message" => error.message }, completed_at: Clock.now)
        emit("turn.failed", error: { "class" => error.class.name, "message" => error.message })
      end

      def apply_result_cost(result, model:)
        cost = Cost.from_usage(result.usage, model: result.model || model)
        add_usage!(result.usage, cost: cost)
        budget.add_cost!(cost.total)
        cost
      end

      def aggregate_cost(current, cost)
        return cost unless current

        Cost.aggregate([ Cost.from_hash(current), cost ])
      end

      def update!(attributes)
        terminal = Background::TERMINAL.include?(attributes[:status])
        store.atomic(Background.root_conversation(store, @record)) do
          if terminal
            if attributes[:status] == "failed" && background?
              executions = Reconciliation.interrupt_tool_executions(@record, store: store)
              Reconciliation.repair_transcript(@record, executions, store: store)
            end
            attributes = attributes.merge(claim_token: nil)
          end
          @record = store.update_turn(id, attributes)
          # The terminal write clears this execution's claim token, so durable
          # callback work must use the unfenced store after that write.
          Background.callback_after_terminal(@base_store, @record) if terminal && background?
          Background.wake(conversation.id, store: @base_store) if terminal && background?
        end
        @started_at = @record["started_at"]
        @model = @record["model"] || agent.effective_model
        @record
      end

      def emit_event(event)
        event = Event.new(type: event[:type] || event["type"], turn_id: id, conversation_id: conversation.id, payload: event[:payload] || event["payload"] || {}) if event.is_a?(Hash)
        Array(@on_event || agent.effective_on_event).each { |callback| callback.call(event) }
      end
  end

  class ToolContext
    attr_reader :turn, :execution

    def initialize(turn:, execution:)
      @turn = turn
      @execution = execution
    end

    def idempotency_key = "turnkit:tool:#{execution.id}"
    def principal = turn.store.load_turn(turn.id).dig("options", "principal")
  end
end
