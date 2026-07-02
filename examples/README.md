# TurnKit Examples

These examples cover the main TurnKit entry points and workflow patterns.

## Core API

[`core_api`](core_api) contains API-key-free examples for the three core shapes:

1. `Conversation` for durable threads over time.
2. `Agent#run` for one bounded application task.
3. an orchestrator `TurnKit::Agent` (`orchestrator: true`) for a reusable task runner with skills, tools, and limits.

## Workflow Researcher

[`workflow_researcher`](workflow_researcher) shows a source-grounded research
workflow with web search, batch page reads, per-tool budgets, compaction, and
deep event monitoring.

Use it when you want to study the recommended single-orchestrator workflow
pattern for deep research style workloads.

The web examples share small dependency-free HTTP clients in `examples/shared/`:
`parallel_client.rb` for Parallel API access, `hunter_client.rb` for Hunter
email discovery, verification, and enrichment, and `apollo_client.rb` for Apollo
people/company search and enrichment. Each example still defines its own TurnKit
tools so the tool contracts stay close to the workflow they support.

## Neighbor Name Researcher

[`neighbor_name_researcher`](neighbor_name_researcher) shows a privacy-minimized
deep-research workflow for recovering a likely neighbor family last name from
user-provided first names, locality, and a legitimate personal context. It uses
Parallel Task API for a quality-first deep pass, optional targeted web follow-up,
and a terminal report tool that rejects obvious sensitive PII.

Use it when you want to study a deep research workflow that deliberately returns
only the minimum identity detail needed for the task, plus confidence, sources,
caveats, and offline verification steps.

## Bay Alarm Lead Researcher

[`bay_alarm_lead_researcher`](bay_alarm_lead_researcher) shows a vertical-specific
cold-outbound prospecting workflow for a Bay Alarm salesperson in Southern
California. It uses GPT-5.5 medium thinking as the orchestrator and Parallel Task,
FindAll, and Entity Search tools for live research, company discovery, account
enrichment, decision-maker lookup, and source-backed lead scoring.

Use it when you want to study a production-shaped lead-generation agent with
strict no-fabrication rules, email provenance constraints, a detailed workflow
skill, and a terminal save tool that renders a validated Markdown lead pack.

## Image Generation

[`image_generation`](image_generation) is a smoke test for TurnKit's first-class
image path. It uses the local `generate-image` CLI to generate a 16:9 Gemini
`nano-banana-pro` image through `Turn#paint` and persists the image result in the
turn history.

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
