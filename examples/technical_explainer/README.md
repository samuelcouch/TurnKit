# Technical Explainer Example

This example builds **SpecReader**, a TurnKit agent that reads technical papers,
RFCs, specs, changelogs, and API docs, then produces implementation-oriented
briefs for software builders.

It showcases:

- system prompt composition from files
- file-based skills
- external tools
- local mutating tools
- subject context
- live context
- source-grounded citations

The only external API used by the example, besides the configured LLM provider,
is Parallel:

- `POST /v1/search`
- `POST /v1/extract`

## Setup

```sh
export PARALLEL_API_KEY=...
export ANTHROPIC_API_KEY=...
# or OPENAI_API_KEY=..., GEMINI_API_KEY=..., OPENROUTER_API_KEY=...
```

Optionally choose a model:

```sh
export TURNKIT_MODEL=claude-sonnet-5
```

Optionally enable provider thinking for models that support it:

```sh
export TURNKIT_MODEL=gpt-5.6-sol
export TURNKIT_THINKING_EFFORT=none
# or, for providers such as Anthropic:
export TURNKIT_MODEL=claude-sonnet-5
unset TURNKIT_THINKING_EFFORT
export TURNKIT_THINKING_BUDGET=4000
```

Sol's tool-calling path requires `none` on Chat Completions and selects it
automatically when no thinking override is supplied. Explicit effort/budget
overrides remain unchanged and must be supported by the selected provider.

## Run

```sh
bundle exec ruby examples/technical_explainer/technical_explainer.rb \
  "Explain https://arxiv.org/abs/2606.03673 for a Ruby engineer building research-analysis tools. Focus on implementation risks."
```

Or ask it to find the source first:

```sh
bundle exec ruby examples/technical_explainer/technical_explainer.rb \
  "Find the current Model Context Protocol spec and explain what a Ruby gem author needs to know."
```

## What to expect

SpecReader should:

1. use `parallel_web_extract` when the request includes a URL
2. use `parallel_web_search` when it needs to find a canonical source
3. prefer primary sources over summaries
4. save extracted documents and the final brief into the example store
5. cite source URLs for factual claims
6. separate source-backed facts from implementation advice

At the end of the run, the script prints the saved source documents and briefs.

If `TURNKIT_MODEL` is not set, the script picks a model based on populated API
keys: `claude-sonnet-5` with `ANTHROPIC_API_KEY`, then `gemini-3.8-flash` with
`GEMINI_API_KEY`, then `gpt-5.6-sol` with `OPENAI_API_KEY`.

## How the prompt is organized

```text
examples/technical_explainer/
  prompts/
    instructions.md      # SpecReader's role and durable behavior rules
    system_prompt.md     # Explicit composition of TurnKit prompt sections
  skills/
    technical_explainer.md     # Markdown skill with name/description frontmatter
    source_finder.md           # Markdown skill with name/description frontmatter
    implementation_review.md   # Markdown skill with name/description frontmatter
  ../shared/
    parallel_client.rb         # Shared Parallel Search/Extract HTTP client
  lib/tools/
    parallel_web_search.rb
    parallel_web_extract.rb
    save_research_brief.rb
    ...
```

The example intentionally does **not** repeat detailed tool-selection rules in
`prompts/instructions.md`. TurnKit already renders a `tools_available` section
from each tool's Ruby `description`, `usage_hint`, and parameters. For example,
`parallel_web_extract` says it should be used before answering URL-backed
document requests. The skills describe workflow phases; the tools describe when
they are available and what they do.
