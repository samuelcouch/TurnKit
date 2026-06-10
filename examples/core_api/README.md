# Core API Examples

These examples show when to use each TurnKit entry point. They use fake clients,
so they run without API keys.

## 1. Conversation: durable thread

Use a conversation when the interaction continues over time and previous
messages should affect future turns.

This example creates one conversation, runs two turns, and shows that the second
model call sees the earlier thread messages.

```sh
ruby examples/core_api/01_conversation.rb
```

## 2. Agent run: one application task

Use `Agent#run` when your app needs one bounded result now: classify, extract,
summarize, route, score, or generate structured output.

This example does one classification run with structured output. There is no
follow-up thread and no reusable workflow policy.

```sh
ruby examples/core_api/02_agent_run.rb
```

## 3. Workflow: reusable task runner

Use `TurnKit::Workflow` when a run becomes a named production capability with a
repeatable procedure, tools, skills, limits, and observability.

This example packages a renewal-risk workflow with a Markdown skill file
(`skills/renewal_risk_review.md`), CRM lookup tool, and runtime limits. The
workflow calls a tool, consumes the result, and returns a recommendation.

```sh
ruby examples/core_api/03_workflow.rb
```

Rule of thumb:

```text
Conversation      = talk over time
Agent#run         = one job now
TurnKit::Workflow = reusable job runner
```

Even the conversation and workflow examples use an `Agent` internally because
`Agent` is the primitive. The question is which shape your application should
hold onto: a durable `Conversation`, a one-off `Run`, or a reusable `Workflow`.

## More workflow examples

- [`../workflow_researcher`](../workflow_researcher) shows source-grounded research with web search, batch page reads, per-tool budgets, and deep monitoring.
- [`../amazon_memo_writer`](../amazon_memo_writer) shows strict memo generation with deterministic format validation, a structured terminal submit tool, and an LLM output policy audit.
