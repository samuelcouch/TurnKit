# frozen_string_literal: true

module TurnKit
  module Compaction
    DEFAULTS = {
      "enabled" => true,
      "threshold" => 0.75,
      "context_limit" => 128_000,
      "reserved_tokens" => 20_000,
      "head_messages" => 0,
      "tail_messages" => 12,
      "tail_tokens" => 8_000,
      "summary_ratio" => 0.20,
      "min_summary_tokens" => 1_000,
      "max_summary_tokens" => 12_000,
      "tool_output_max_chars" => 2_000,
      "model" => nil,
      "client" => nil
    }.freeze

    KNOWN_KEYS = DEFAULTS.keys.freeze

    COMPACTION_SYSTEM_PROMPT = <<~TEXT.strip
      You are an anchored context summarization assistant for TurnKit conversations.

      Summarize only the conversation history you are given. Recent turns may be kept verbatim outside your summary, so focus on older context that still matters for continuing the work.

      If a previous summary is provided, update it by preserving still-true details, removing stale details, and merging in new facts.

      Produce only the requested Markdown summary. Do not answer the conversation itself. Do not mention that you are summarizing, compacting, or merging context.

      Write in the same language the user was using.

      Never include API keys, tokens, passwords, secrets, credentials, or connection strings. Replace secret values with [REDACTED].
    TEXT

    SUMMARY_TEMPLATE = <<~TEXT.strip
      Use this exact structure:

      ## Active Task
      - [latest unfulfilled user request, preferably verbatim]

      ## Goal
      - [what the user is trying to accomplish overall]

      ## Constraints & Preferences
      - [user/developer preferences, specs, constraints, important choices]

      ## Completed Actions
      - [completed work and outcomes]

      ## Active State
      - [current state, records/files touched, test status, running tool/turn state]

      ## In Progress
      - [work underway, or "(none)"]

      ## Blocked
      - [blockers, exact errors, missing information, or "(none)"]

      ## Key Decisions
      - [important decisions and why]

      ## Resolved Questions
      - [questions already answered]

      ## Pending User Asks
      - [unanswered or unfulfilled asks]

      ## Relevant Files
      - [file/path/resource and why it matters, or "(none)"]

      ## Tool Results To Remember
      - [important tool output summaries, or "(none)"]

      ## Remaining Work
      - [likely next work, framed as context, not instructions]

      ## Critical Context
      - [specific values, IDs, commands, errors, constraints; redact secrets]

      Rules:
      - Keep every section.
      - Use terse bullets.
      - Preserve exact file paths, commands, error strings, IDs, and important values.
      - Do not invent facts.
      - Do not include secrets.
      - Do not include a greeting or preamble.
    TEXT

    module_function

    def enabled_for?(agent, overrides = {})
      policy_for(agent, overrides)["enabled"]
    end

    def policy_for(agent, overrides = {})
      global = normalize_config(TurnKit.compaction)
      local = normalize_config(agent.compaction)
      override = normalize_config(overrides)

      return DEFAULTS.merge("enabled" => false) if global == false
      return DEFAULTS.merge("enabled" => false) if local == false
      return DEFAULTS.merge("enabled" => false) if override == false

      DEFAULTS.merge(global || {}).merge(local || {}).merge(override || {})
    end

    def maybe_compact!(turn, force: nil, focus: nil)
      return if turn.compact == false

      force = turn.compact == true if force.nil?
      policy = policy_for(turn.agent)
      return unless policy["enabled"]

      messages = project(turn.conversation.messages_for_turn(turn))
      return unless force || over_threshold?(messages, policy)

      compact!(turn.conversation, agent: turn.agent, turn: turn, focus: focus, auto: true, overrides: policy, force: true)
    rescue BudgetError
      raise
    rescue StandardError => error
      TurnKit.logger&.warn("TurnKit compaction failed: #{error.class}: #{error.message}")
      nil
    end

    def compact!(conversation, agent:, turn: nil, focus: nil, auto: false, overrides: {}, force: true)
      policy = policy_for(agent, overrides)
      raise CompactionError, "compaction is disabled" unless policy["enabled"]

      messages = turn ? conversation.messages_for_turn(turn) : conversation.messages
      projected = project(messages)
      selected = select_messages(projected, policy)
      return nil if selected.nil? && auto
      raise CompactionError, "not enough messages to compact" unless selected

      selected_tokens = estimate_messages_tokens(selected.fetch("middle"))
      return nil if auto && !force && !over_threshold?(projected, policy)

      summary = generate_summary(
        agent: agent,
        policy: policy,
        messages: selected.fetch("middle"),
        previous_summary: selected["previous_summary"]&.text,
        focus: focus,
        target_tokens: summary_budget(selected_tokens, policy),
        fallback_model: turn&.model || conversation.model || agent.effective_model,
        conversation_id: conversation.id,
        turn_id: turn&.id,
        turn: turn
      )

      append_summary(conversation, turn: turn, summary: summary, selected: selected, policy: policy, focus: focus, auto: auto, input_tokens: selected_tokens)
    rescue CompactionError
      raise
    rescue BudgetError
      raise
    rescue StandardError => error
      raise CompactionError, "#{error.class}: #{error.message}"
    end

    def project(messages)
      rows = Array(messages).sort_by { |message| [ message.sequence.to_i, message.id ] }
      summaries = active_summaries(rows)
      ranges = summaries.filter_map { |summary| range_for(summary) }
      summaries_by_id = summaries.to_h { |summary| [ summary.id, summary ] }
      inserted = {}
      projected = []

      rows.each do |message|
        summaries.each do |summary|
          range = range_for(summary)
          next unless range
          next if inserted[summary.id]
          next unless range.begin <= message.sequence.to_i

          projected << summary
          inserted[summary.id] = true
        end

        if message.context_summary?
          projected << message if summaries_by_id[message.id] && !inserted[message.id] && !range_for(message)
          inserted[message.id] = true if summaries_by_id[message.id]
          next
        end

        next if ranges.any? { |range| range.cover?(message.sequence.to_i) }

        projected << message
      end

      summaries.each do |summary|
        next if inserted[summary.id]

        projected << summary
        inserted[summary.id] = true
      end

      projected
    end

    def estimate_messages_tokens(messages)
      Array(messages).sum { |message| estimate_text_tokens(message.text) + 8 }
    end

    def estimate_text_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    def summary_budget(input_tokens, policy)
      budget = (input_tokens.to_i * policy["summary_ratio"].to_f).ceil
      budget = [ budget, policy["min_summary_tokens"].to_i ].max
      [ budget, policy["max_summary_tokens"].to_i ].min
    end

    def over_threshold?(messages, policy)
      usable = [ policy["context_limit"].to_i - policy["reserved_tokens"].to_i, 1 ].max
      estimate_messages_tokens(messages) >= (usable * policy["threshold"].to_f)
    end

    def select_messages(messages, policy)
      rows = Array(messages)
      return nil if rows.length <= policy["head_messages"].to_i + 1

      previous_summary = rows.reverse.find(&:context_summary?)
      candidates = rows.reject(&:context_summary?)
      return nil if candidates.length <= policy["head_messages"].to_i + 1

      head_count = policy["head_messages"].to_i
      tail_start = tail_start_index(candidates, policy)
      tail_start = [ tail_start, head_count ].max
      tail_start = expand_tail_start_for_tool_pairs(candidates, tail_start)
      middle = candidates[head_count...tail_start]
      return nil if middle.nil? || middle.empty?

      from_sequence = middle.first.sequence.to_i
      through_sequence = middle.last.sequence.to_i
      if previous_summary
        from_sequence = [ from_sequence, previous_summary.sequence.to_i ].min
        through_sequence = [ through_sequence, previous_summary.sequence.to_i ].max
      end

      {
        "middle" => middle,
        "previous_summary" => previous_summary,
        "replaces_from_sequence" => from_sequence,
        "replaces_through_sequence" => through_sequence,
        "tail_start_sequence" => candidates[tail_start]&.sequence
      }
    end

    def build_prompt(previous_summary:, focus:, target_tokens:)
      parts = []
      if previous_summary && !previous_summary.empty?
        parts << <<~TEXT.strip
          Update the anchored summary below using the conversation history above.

          Preserve still-true details, remove stale details, and merge in new facts. Remove stale details that are no longer relevant or have been superseded.

          <previous-summary>
          #{previous_summary}
          </previous-summary>
        TEXT
      else
        parts << <<~TEXT.strip
          Create a structured context checkpoint for the conversation history above.

          This summary will replace older TurnKit messages in future model prompts while the original messages remain stored durably.
        TEXT
      end

      if focus && !focus.to_s.strip.empty?
        parts << <<~TEXT.strip
          Focus topic: "#{focus}"

          Preserve extra detail related to this focus topic. Summarize unrelated context more aggressively, but do not omit constraints or active blockers that affect the current task.
        TEXT
      end

      parts << "Target length: approximately #{target_tokens} tokens."
      parts << SUMMARY_TEMPLATE
      parts.join("\n\n")
    end

    def normalize_config(value)
      case value
      when nil, true
        nil
      when false
        false
      when Hash
        attrs = value.transform_keys(&:to_s)
        unknown = attrs.keys - KNOWN_KEYS
        raise ConfigError, "unknown compaction options: #{unknown.join(", ")}" if unknown.any?

        attrs
      else
        raise ConfigError, "compaction must be true, false, nil, or a Hash"
      end
    end

    def range_for(summary)
      metadata = summary.compaction_metadata
      from = metadata["replaces_from_sequence"]
      through = metadata["replaces_through_sequence"]
      return nil unless from && through

      (from.to_i..through.to_i)
    end

    def active_summaries(messages)
      summaries = Array(messages).select(&:context_summary?).sort_by { |summary| summary.sequence.to_i }
      active = []

      summaries.reverse_each do |summary|
        next if active.any? { |newer| (range_for(newer)&.cover?(summary.sequence.to_i)) }

        active << summary
      end

      active.reverse
    end

    def tail_start_index(messages, policy)
      max_messages = policy["tail_messages"].to_i
      max_tokens = policy["tail_tokens"].to_i
      count = 0
      tokens = 0
      index = messages.length

      (messages.length - 1).downto(0) do |i|
        message_tokens = estimate_text_tokens(messages[i].text) + 8
        break if count >= max_messages
        break if count.positive? && tokens + message_tokens > max_tokens

        count += 1
        tokens += message_tokens
        index = i
      end

      index
    end

    def expand_tail_start_for_tool_pairs(messages, tail_start)
      index = tail_start
      while index.positive? && messages[index]&.tool_result?
        call_id = messages[index].metadata["tool_call_id"]
        call_index = (index - 1).downto(0).find do |i|
          messages[i].tool_call? && Array(messages[i].metadata["tool_calls"]).any? { |call| call["id"] == call_id || call[:id] == call_id }
        end
        break unless call_index

        index = call_index
      end
      index
    end

    def generate_summary(agent:, policy:, messages:, previous_summary:, focus:, target_tokens:, fallback_model:, conversation_id:, turn_id:, turn: nil)
      client = policy["client"] || agent.effective_client
      model = policy["model"] || fallback_model
      safe_messages = messages.map { |message| sanitize_message(message, policy) }
      prompt = build_prompt(previous_summary: previous_summary, focus: focus, target_tokens: target_tokens)
      attrs = {
        model: model,
        messages: MessageProjection.for(safe_messages) + [ { role: :user, content: prompt } ],
        tools: [],
        instructions: COMPACTION_SYSTEM_PROMPT,
        metadata: { compaction: true, conversation_id: conversation_id, turn_id: turn_id }
      }
      result = if turn
        turn.internal_model_call(**attrs, purpose: "compaction", client: policy["client"])
      else
        client.validate!(model: model)
        client.chat(**attrs)
      end
      text = result.text.to_s.strip
      raise CompactionError, "compaction model returned an empty summary" if text.empty?

      text
    end

    def sanitize_message(message, policy)
      return message unless message.tool_result?

      max = policy["tool_output_max_chars"].to_i
      return message if max <= 0 || message.text.length <= max

      attrs = message.to_h
      text = "#{message.text[0, max]}\n\n[Tool result truncated for compaction]"
      Message.new(attrs.merge("text" => text, "content" => [ { "type" => "text", "text" => text } ]))
    end

    def append_summary(conversation, turn:, summary:, selected:, policy:, focus:, auto:, input_tokens:)
      model = policy["model"] || turn&.model || conversation.model || conversation.agent.effective_model
      conversation.append_message(
        role: "assistant",
        kind: "context_summary",
        text: summary,
        turn_id: turn&.id,
        metadata: {
          "compaction" => {
            "auto" => auto,
            "focus" => focus,
            "replaces_from_sequence" => selected.fetch("replaces_from_sequence"),
            "replaces_through_sequence" => selected.fetch("replaces_through_sequence"),
            "tail_start_sequence" => selected["tail_start_sequence"],
            "summary_model" => model,
            "input_tokens" => input_tokens,
            "summary_tokens" => estimate_text_tokens(summary),
            "created_for_turn_id" => turn&.id,
            "created_at" => Clock.now.iso8601
          }.compact
        }
      )
    end
  end
end
