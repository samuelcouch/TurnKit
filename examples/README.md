# TurnKit Examples

Start with the small examples, then move to the production-shaped reference app.
The domain-specific examples remain available for readers who need those use
cases, but they are not part of the core onboarding path.

## Recommended path

1. **Core API, offline:** [`core_api`](core_api) contains three API-key-free
   examples covering `Conversation`, one bounded `Agent#run`, and a reusable
   orchestrator agent. Start here to choose the right API shape.
2. **Simple live workflow:** [`workflow_researcher`](workflow_researcher) shows
   the recommended single-orchestrator research pattern with web tools,
   guardrails, compaction configuration, and monitoring.
3. **Strict output:** [`amazon_memo_writer`](amazon_memo_writer) adds a terminal
   structured submit tool, deterministic rendering and audits, and semantic
   output-policy review.
4. **Larger agent composition:** [`technical_explainer`](technical_explainer)
   demonstrates prompt files, skills, local support objects, source-grounded
   tools, and saved working data.
5. **Durable reference app:** [`durable_research`](durable_research) is the
   flagship Rails/Postgres/Solid Queue headless app. It defaults to a
   deterministic fake mode, offers opt-in live execution, and covers normal,
   conversation, messaging, recovery, and media scenarios. See its README for
   setup and run instructions.
6. **Media helpers:** [`media_analysis`](media_analysis) and
   [`image_generation`](image_generation) are focused smoke tests for media input
   analysis and image generation.

For a complete live skill/context demonstration, run [`recipe_builder`](recipe_builder):
high-thinking recipe research, on-demand skill loading, changing injected context,
a reviewer subagent, and validated recipe JSON with source URLs.

For open-ended idea generation, run [`deep_research`](deep_research): high-thinking
research questions, Parallel search, an independent adjacent-field thread working
alongside an evidence subagent, skeptical review, and cited ideas with experiments.

## What each example proves

| Example | Network/model mode | Primary coverage | Restart durability |
| --- | --- | --- | --- |
| `core_api` (3 scripts) | Offline fake clients | Conversation, bounded run, orchestrator | No; the examples use memory-only state |
| `workflow_researcher` | Live | Simple source-grounded workflow, tools, limits, monitoring | No; memory-only |
| `recipe_builder` | Live | On-demand skills, dynamic context, high-thinking research/review, cited recipe JSON | No; memory-only |
| `deep_research` | Live | Research questions, adjacent-field synthesis, detached launch, overlapping branches, join, critique, cited JSON | Yes; reuses the durable app's PostgreSQL/Solid Queue boot |
| `amazon_memo_writer` | Live | Strict structured submission and output audits | No; memory-only |
| `technical_explainer` | Live | Prompt/skill composition, local stores, research tools | No; memory-only |
| `durable_research` | Offline fake by default; live is opt-in | Rails/Postgres/Solid Queue, conversations, messaging, recovery, media | Yes; this is the restart-durability reference |
| `media_analysis` | Live | Image, PDF, audio, video, and URL analysis path | No; memory-only |
| `image_generation` | Live | Image generation and image-message persistence path | No; memory-only |

“Conversation” and “persistence” in the smaller examples describe behavior within
their in-memory example process; they do not demonstrate survival across a
process restart. Likewise, an example that configures a budget or compaction
threshold proves that configuration path, not that the limit or compaction was
actually triggered during a particular run. Use `durable_research` when you need
the end-to-end durability and recovery reference.

## Optional domain demonstrations

These specialized live examples are useful demonstrations, not prerequisites:

- [`bay_alarm_lead_researcher`](bay_alarm_lead_researcher) is a
  vertical-specific cold-outbound prospecting workflow with company discovery,
  enrichment, source-backed lead scoring, strict no-fabrication rules, and a
  validated Markdown lead pack.
- [`neighbor_name_researcher`](neighbor_name_researcher) is a
  privacy-minimized identity-recall workflow using deep research, targeted
  follow-up, a terminal report tool, and explicit sensitive-PII restrictions.

The web examples share the dependency-free
`examples/shared/parallel_client.rb` client for Parallel API access. Each example
defines its own TurnKit tools so their contracts stay close to the workflow they
support.

## Live model defaults

Research and memo examples target `gpt-5.6-sol`; technical explanation selects
`claude-sonnet-5`, `gemini-3.8-flash`, or `gpt-5.6-sol` according to available
provider keys. Media analysis uses `gemini-3.8-flash`, and image generation uses
`gpt-image-2`. These are task-specific choices from RubyLLM's current catalog,
not a guarantee of account access or measured superiority on every task.

Use `TURNKIT_MODEL`, `TURNKIT_MEDIA_MODEL`, or `TURNKIT_IMAGE_MODEL` to override
the corresponding example. When a chosen model is missing from the installed
RubyLLM catalog, live examples refresh the in-memory registry from configured
providers before running. This requires network access but performs no inference.
Missing models or credentials fail rather than silently switching providers.
The core API examples remain offline and do not refresh the registry.
