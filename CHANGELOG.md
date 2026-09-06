# Changelog

## 0.6.0 - 2026-09-06

### Added

- Independent background submission through Active Job, registered agent reconstruction, durable messages/completion callbacks, inbox/outbox queries, and worker-free joins.
- Parallel background sub-agents with persisted parent/child lineage and ordered results; opt-in launch, send-message, and wait tools.
- Persisted execution phases, fenced claims, root-wide budget reservations, and recovery of missed enqueues and abandoned workers without replaying unknown external effects.
- PostgreSQL concurrency/process-death tests and a reversible `turnkit:upgrade` migration generator.
- Agent-scoped context and skills, extensible specialist factories, authorization hooks, and fenced cancellation with explicit descendant handling.
- Live recipe, deep-research and rare-earth policy examples, plus prepared orb dependencies and OIDC-based RubyGems releases.

### Fixed

- Reject conflicting delivery-key reuse without disclosing another conversation's payload; authorize implicit joins and detect conversation-lane wait cycles.
- Bound inline reconciliation queries and preserve replay-safe tool keys and skill activation across recovery.
- Forward image references and normalize RubyLLM provider failures as terminal model errors instead of repeatedly retrying permanent failures.

### Breaking

- Existing ActiveRecord installations must run `turnkit:upgrade` and migrate; turn records gain `submitted_at` and `claim_token`, plus delivery and wait tables.
- Custom stores must implement the new transactional coordination contract. Reconciled inline workers lose write authority; `stale` is no longer provisional.
- Background execution requires Active Job 7.2+ and a persistent queue backend. `async: true` remains previewable pending work; call `perform_later` to submit.

## 0.5.0 - 2026-07-22

### Breaking

- Custom stores: `find_stale_turns` is replaced by `reconcile_stale_turns(before:)`, which must atomically transition eligible turns to `stale` and return the reconciled records. `update_tool_execution` is replaced by `claim_tool_execution(id, from:, to:, **attributes)`, an atomic compare-and-set mirroring `claim_turn`.

### Fixed

- Make stale-turn reconciliation atomic, so `TurnKit.reconcile_stale!` can no longer overwrite a turn that was concurrently claimed, heartbeated, or completed (#1).
- Heartbeat while a tool executes, so tools slower than `TurnKit.timeout` are not falsely reconciled.

### Added

- Add an `interrupted` tool-execution status. Reconciliation marks a stale turn's unfinished tool executions `interrupted`, appends a synthetic error tool result for unresolved tool calls (keeping the transcript continuable), and emits `turn.stale` and `tool_call.interrupted` events. Late tool results arriving after interruption are dropped, never overwriting the reconciled state.
- `TurnKit.reconcile_stale!` returns the reconciled turn records. `stale` is provisional: a worker whose heartbeats were merely late finishes its turn normally, replacing `stale` with the actual outcome.

## 0.4.2 - 2026-07-02

### Breaking

- Remove `TurnKit::Workflow`; use `TurnKit::Agent.new(orchestrator: true, ...)` for reusable autonomous task runners.
- Make `Agent#run` task positional, remove `TurnKit.model` aliases, and rename run accessors to `output_text` and `tool_executions`.
- Simplify tool context injection to `context:`, reserve `context` as a tool parameter name, and reduce `SubAgentTool` input to `task`.
- Replace prompt contributor APIs with per-agent `system_prompt:` customization and stable/dynamic `TurnKit::SystemPrompt` accessors.
- Strictly validate custom cost-rate keys, remove `MediaAnalysisResult#structured?`, remove Rails record-class globals, and require atomic custom store `claim_turn` implementations.
- Remove `ruby_llm` as a runtime dependency; add `gem "ruby_llm", "~> 1.16"` when using the default RubyLLM adapter.
- Call custom clients with the full `TurnKit::Client` keyword contracts, including `dynamic_instructions:` for split stable/dynamic prompts.

### Changed

- Keep the Rails install generator under the conventional `lib/generators` path without a Railtie.
- Document compaction config with symbol keys while continuing to accept string keys.
- Persist turn runtime state under `options["state"]` with backward-compatible reads.

## 0.4.1 - 2026-06-19

- Add first-class media analysis with `Turn#view_media`, `TurnKit.view_media`, and `TurnKit::ViewMediaTool`.
- Normalize media inputs for paths, URLs, IO/bytes, and Rails Active Storage-compatible attachments.
- Persist media analysis messages with model, provider, usage, cost, structured output, events, and output policy support.
- Add a Gemini 3 Flash media-analysis smoke example.

## 0.4.0 - 2026-06-19

- Add first-class image generation with `Turn#paint`, `TurnKit.paint`, and `TurnKit::ImageTool`.
- Persist generated images as durable image messages with normalized metadata, usage, cost, and event callbacks.
- Add image output policy support and a `generate-image` CLI smoke example for Gemini 16:9 image generation.

## 0.3.0 - 2026-06-10

- Make the task-runtime API skills-first and intentionally breaking: `max_spend` is the only spend-limit name and output validation is exposed as `output_policy` / `policy_audit`.
- Store message content as ordered typed parts, with text derived from content and tool calls/results persisted in the transcript instead of metadata.
- Add `load_skill` for progressively disclosed available skills.
- Add output-policy revision loops with `output_retries`, including skill/policy rehydration in revision prompts.
- Add deterministic `input_schema` validation before turns are created.
- Ensure terminal tools never orphan sibling tool calls; skipped siblings receive cancelled executions and tool-result messages.
- Add turn claiming, tool-runner heartbeats, persisted budget resume, and sub-agent failure details.

## 0.2.10 - 2026-06-10

- Add output audits and file-backed output policies for validating final run output.
- Add per-tool execution limits and explicit budget errors.
- Improve workflow event callbacks, model telemetry events, and compaction usage accounting.
- Add an Amazon memo writer example and batched page reading in the workflow researcher example.

## 0.2.9 - 2026-06-08

- Add `TurnKit::Workflow` for reusable single-orchestrator task runtimes with workflow skills, tools, guardrails, compaction, and run monitoring.
- Add `Agent#run` and `TurnKit::Run` for non-interactive application tasks, with task prompt behavior by default.
- Improve task-runtime DX with `TurnKit.configure`, `TurnKit.model`, `TurnKit.max_spend`, `TurnKit::Workflow`, positional `run("task")`, `run.output`, `run.tool_calls`, and `Tool.terminal!`.
- Support tool instances with constructor-injected dependencies.
- Add a workflow researcher example and upgrade guide.

## 0.2.6 - 2026-06-07

- Add automatic context compaction for long conversations. TurnKit now stores append-only `context_summary` messages and projects compacted history into future model calls while keeping the full transcript durable.

## 0.2.5 - 2026-06-06

- Add per-agent and per-turn provider thinking configuration.

## 0.2.4 - 2026-06-06

- Add Anthropic prompt cache support for stable system prompt sections.
- Track cache write tokens and expose model cost totals for turns, conversations, and agents.
- Calculate costs from RubyLLM model registry pricing with custom rate and calculator overrides.
- Refresh README usage examples for prompt caching and usage tracking.

## 0.2.0 - 2026-06-04

- Add configurable system prompt sections and custom system prompt builders.
- Add globally and per-agent available skills for prompt guidance.
- Add skill loading from directories.

## 0.1.0 - 2026-06-04

- Initial release of TurnKit.
- Add durable conversations, turns, messages, tool calls, tool executions, and usage tracking.
- Add in-memory storage and optional Active Record-backed persistence.
- Add RubyLLM adapter support for model calls and provider API keys.
- Add tool, terminal-tool, skill, and sub-agent primitives.
