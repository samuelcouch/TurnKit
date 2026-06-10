# Changelog

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
