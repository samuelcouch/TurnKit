# Changelog

## 0.2.3 - 2026-06-06

- Add Anthropic prompt cache support for stable system prompt sections.
- Track cache write tokens and aggregate model costs on turns.
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
