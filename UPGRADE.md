# Upgrade Guide

## 0.4.2

TurnKit 0.4.2 is a pre-1.0 surface cleanup. Update these call sites before upgrading:

- `TurnKit::Workflow.new(...)` → `TurnKit::Agent.new(orchestrator: true, ...)`. Orchestrator agents prepend the same autonomous-orchestrator preamble and default `prompt_mode` to `:task`.
- `workflow.run(task, max_spend: ...)` / other per-run workflow overrides → configure those limits on the `Agent`; agents are cheap to construct.
- `workflow.agent(**overrides)` → construct another `TurnKit::Agent` with the desired options.
- `agent.run(task: "...")` → `agent.run("...", input: ..., async: ...)`.
- `TurnKit.model` / `TurnKit.model=` → `TurnKit.default_model` / `TurnKit.default_model=`.
- `run.output` → `run.output_text`.
- `run.tool_calls` → `run.tool_executions`.
- `run.steps` and `run.persisted?` were removed.
- Tool framework context is always passed as `context:`. The `turnkit_context:` alternative was removed, and `context` is now a reserved tool parameter name.
- `TurnKit::SubAgentTool` exposes a single model-visible `task` parameter.
- Prompt extension hooks `TurnKit.system_prompt_contributors`, `TurnKit.model_prompt_contributors`, `TurnKit::PromptContribution`, and prompt section override objects were removed. Pass `system_prompt:` to `TurnKit::Agent` instead: a string replaces the generated prompt; a callable receives `TurnKit::SystemPrompt` and returns the final string.
- `TurnKit::SystemPrompt` supports `to_s`, `section(:tools)`, `stable`, and `dynamic`. `TurnKit.prompt_sections`, per-agent `prompt_sections:`, `TurnKit.prompt_behavior`, and `TurnKit.context_contributors` remain.
- `TurnKit.cost_rates` accepts only `input`, `output`, `cache_read`, `cache_write`, and `thinking` keys, expressed as USD per million tokens. Old aliases such as `cached_input`, `cache_creation`, `reasoning`, and `*_per_million` now raise `TurnKit::ConfigError`.
- `MediaAnalysisResult#structured?` → `MediaAnalysisResult#data?`.
- Rails record class globals (`TurnKit.conversation_record_class`, turn/message/tool_execution variants) were removed. Pass class names to the store: `TurnKit::ActiveRecordStore.new(conversation_class: "My::Conversation", turn_class: "My::Turn", message_class: "My::Message", tool_execution_class: "My::ToolExecution")`.
- The Railtie was removed. `rails g turnkit:install` still works through the conventional `lib/generators` path.
- `ruby_llm` is no longer a runtime dependency. To use the default RubyLLM adapter, add `gem "ruby_llm", "~> 1.16"` to your Gemfile. The Codex adapter and custom `TurnKit::Client` subclasses need no extra gems.
- Custom clients are called with the full `TurnKit::Client` keyword contracts for `chat`, `paint`, and `view_media`; signature sniffing was removed. Subclass `TurnKit::Client` or accept the full keyword sets.
- `Client#chat` gained `dynamic_instructions:`. Cache the stable `instructions` string and append `dynamic_instructions` per turn when the provider supports prompt caching.
- `SystemPrompt::CACHE_BOUNDARY`, `split_cache_boundary`, and the `has_cache_boundary` prompt report field were removed. `SystemPrompt#report` keeps `stable_chars` and `dynamic_chars`.
- `TurnKit::Store#claim_turn` no longer has a default implementation. Custom stores must implement an atomic compare-and-set claim.
- Compaction configuration examples now use symbol keys; string keys are still accepted.

Non-breaking: turn runtime state such as iterations and policy audit now persists under `options["state"]` with backward-compatible reads.

## 0.3.0 is a clean break

TurnKit 0.3.0 intentionally removes the short-lived legacy names from the 0.2
series. The gem is pre-1.0 and the durable transcript schema changed, so migrate
by updating call sites and reinstalling the generated tables for new projects.

### Renames

- `TurnKit.cost_limit` → `TurnKit.max_spend`
- `Agent.new(cost_limit:)` → `Agent.new(max_spend:)`
- `Workflow.new(cost_limit:)` / `workflow.run(cost_limit:)` → `max_spend:`
- `output_audit:` → `output_policy:`
- `output_audit_mode:` → `output_policy_mode:`
- `run.output_audit` → `run.policy_audit`
- `run.output_audit_clean?` → `run.policy_clean?`
- `TurnKit.audit_output(...)` → `TurnKit.check_output_policy(...)`

The audit result class remains `TurnKit::OutputAudit`; only the public option and
run-accessor names changed.

### Message schema

`turnkit_messages.text` was removed. Message `content` is now the canonical
ordered array of parts:

- `text`
- `thinking`
- `tool_call`
- `tool_result`
- opaque provider parts

`Message#text` is derived from text parts. New Rails installs should regenerate
the install migration; there is no compatibility shim for older schemas.

### Workflows

`TurnKit::Workflow` now forwards options directly to `Agent`. Use
`workflow.options[:name]` or `workflow.agent` for inspection instead of per-option
workflow attr readers. Workflow `instructions:` compose with the orchestrator
preamble by default; pass `preamble: false` to opt out.

### Skills and policy loops

- `available_skills:` now exposes a real `load_skill` tool.
- `output_policy:` accepts `TurnKit::Skill` instances.
- `output_retries:` controls bounded revision loops. The default policy mode is
  now `:fail`; use `output_policy_mode: :report` if dirty output should complete.
- `input_schema:` validates application input before any conversation or turn is
  created.
