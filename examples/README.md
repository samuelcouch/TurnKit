# TurnKit Examples

These examples cover the main TurnKit entry points and workflow patterns.

## Core API

[`core_api`](core_api) contains API-key-free examples for the three core shapes:

1. `Conversation` for durable threads over time.
2. `Agent#run` for one bounded application task.
3. `TurnKit::Workflow` for a reusable task runner with skills, tools, and limits.

## Workflow Researcher

[`workflow_researcher`](workflow_researcher) shows a source-grounded research
workflow with web search, batch page reads, per-tool budgets, compaction, and
deep event monitoring.

Use it when you want to study the recommended single-orchestrator workflow
pattern for deep research style workloads.

## Amazon Memo Writer

[`amazon_memo_writer`](amazon_memo_writer) shows a stricter production-style
workflow: research first, read sources, submit structured memo fields through a
terminal tool, render Markdown in Ruby, run deterministic output audits, and use
an LLM output policy for semantic review.

Use it when you want to study exact-output workflows where prompts alone are not
reliable enough.

## Technical Explainer

[`technical_explainer`](technical_explainer) is a larger example for prompt files,
local support objects, and explanatory agent behavior.
