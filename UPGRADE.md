# Upgrade Guide

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
