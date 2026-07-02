# Neighbor Name Researcher Example

This example shows a deep-research workflow for a narrow identity-recall task:

> “I live in Bryn Mawr, PA. My neighbors are Billy/William and his wife is
> Kelly/Kelli/Kelley. Kelly/Kelli/Kelley is a medical professional, likely at
> Bryn Mawr Hospital or in the Main Line Health network. Billy/William works in
> sales and has also coached hockey. Their daughter Grace was born around a year
> ago. Help me remember their last name for wedding invitations.”

It uses Parallel’s Task API for one quality-first deep research pass, plus small
web-search/page-read tools for targeted follow-up. The terminal save tool renders
a privacy-minimized Markdown report and rejects obvious sensitive PII such as
street addresses, phone numbers, and emails.

## What it demonstrates

- an orchestrator `TurnKit::Agent` (`orchestrator: true`) for a reusable deep-research task runner
- Parallel Task API via `examples/shared/parallel_client.rb`
- a structured output schema for deep identity-recall research
- targeted follow-up tools for web search and batch page reading
- a workflow skill that teaches privacy-minimized research behavior
- a terminal `submit_candidate_report` tool that validates and renders output
- optional `DEEP_MONITORING=1` event logging

## Setup

Use OpenAI or any RubyLLM-supported provider:

```sh
export OPENAI_API_KEY=...
export TURNKIT_MODEL=gpt-5.5
```

The research tools use Parallel:

```sh
export PARALLEL_API_KEY=...
```

The default deep processor is `ultra`:

```sh
export PARALLEL_DEEP_PROCESSOR=ultra
```

## Run

Run the built-in example request:

```sh
bundle exec ruby examples/neighbor_name_researcher/neighbor_name_researcher.rb
```

Or pass a similar identity-recall request:

```sh
bundle exec ruby examples/neighbor_name_researcher/neighbor_name_researcher.rb \
  "I live in Bryn Mawr, PA - my neighbor is Billy/William and his wife is Kelly/Kelli/Kelley. Kelly/Kelli/Kelley is a medical professional, likely at Bryn Mawr Hospital or Main Line Health. Billy/William works in sales and has also coached hockey. Their daughter Grace was born around a year ago. Help me remember their last name (sending wedding invitations)."
```

Add deep monitoring:

```sh
DEEP_MONITORING=1 bundle exec ruby examples/neighbor_name_researcher/neighbor_name_researcher.rb
```

## Privacy guardrails

The example is intentionally not a people-search/contact-data workflow. It asks
for only the last name needed for the invitation task and omits sensitive details:

- no exact street addresses;
- no personal emails;
- no phone numbers;
- no birth dates;
- no unnecessary details about minors.

The final report should include candidates, confidence, source URLs, caveats, and
offline verification steps so the user can confirm before sending invitations.

## Shape of the workflow

```text
model → deep_identity_research → optional web_search/read_web_pages → submit_candidate_report
```

The deep pass is constrained to public sources and a structured JSON schema. The
model then decides whether targeted follow-up is necessary before submitting the
privacy-minimized report.
