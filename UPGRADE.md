# Upgrade Guide

## 0.6.0: Runtime hardening

Configure global context/skills at boot, before constructing agents; defaults are now
snapshotted. Use agent-scoped `context_contributors:` and run-scoped `context:` for requests.
Specialist factories disable global inheritance and validate read-only skill tools.
Skill-owned tools activate only after successful loading in the current turn.

Configure `TurnKit.authorization_policy` and pass authenticated `principal:` values for
multi-user applications. The default remains trusted application code. Submitted cancellation
is terminal and fenced, with explicit `descendants: :retain` or `:cascade` semantics.

PostgreSQL is required for ActiveRecord wait-graph locking. Custom stores must implement
atomic graph operations and bounded actionable queries. Earlier durable-schema adopters
need the two indexes in [runtime hardening](docs/runtime-hardening.md); new install/upgrade
migrations already contain them. That guide also documents stable tool idempotency keys,
opt-in replay safety and the limits of external-effect recovery.

Delivery key reuse with different routing or payload now raises `ToolError` instead of
returning the original message. Implicit subagent joins honor `:wait` policy. Cycle
checks conservatively include all unfinished turns in a conversation's serial lane.
Custom stores also need `list_stale_inline_turns(before:, limit:)`; public inline
reconciliation now drains bounded batches rather than all history in one call.

## 0.6.0: Durable background execution

Stop existing workers before upgrading: older workers do not respect claim
fencing. Generate and apply the additive migration, then restart the application
and workers together:

```sh
bin/rails generate turnkit:upgrade
bin/rails db:migrate
```

Use `--table-prefix your_prefix` if your installation uses custom table names.
The generator adds delivery/wait models and a reversible migration; it does not
replace existing models or delete conversation history. For custom model names,
pass `delivery_class:` and `wait_class:` to `ActiveRecordStore` alongside the
existing model-class options.

Background execution requires Active Job 7.2+ with a persistent queue adapter,
agent registration at boot in every worker, and a recurring
`TurnKit::ReconcileJob`. See [background execution](README.md#background-execution-and-agent-messaging)
for examples and operational semantics. `async: true` does not enqueue work.

Custom stores need reentrant, rollback-capable `atomic(conversation_id)` with
cross-process locking for durable use, submitted-turn queries, delivery CRUD
with a unique idempotency key, and idempotent wait relations. Turn statuses now
include `waiting`; turn records carry `submitted_at` and `claim_token`.
The base store implements inline stale reconciliation using these primitives.

Do not rely on a late worker overwriting a reconciled stale turn. Its claim is
now revoked. Execution-owned writes must go through `context.turn.store`, not a
global/raw store. Background limits are rooted in persisted run configuration;
timeout includes queue and wait time after submission. Inline use needs no job
backend, but ActiveRecord schemas and custom store contracts still need updating.

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
