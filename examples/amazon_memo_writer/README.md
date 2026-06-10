# Amazon Memo Writer Example

This example stress-tests a strict workflow that must research, read sources,
draft, edit, and then submit an Amazon-style memo through a structured terminal
tool.

The `web_search` and `read_web_page` tools use Parallel Search and Extract, so
sources come from real web research. The deterministic parts of the example are
the submit tool, Markdown renderer, and format audit.

## What it demonstrates

- `TurnKit::Workflow` as a reusable task runner
- tool use before final output
- per-tool budgets with `max_tool_executions_by_name`
- a terminal submit tool that renders exact Markdown
- Markdown skill files with `name` / `description` frontmatter
- deterministic output audits for strict format rules
- an LLM `TurnKit::OutputPolicy` for semantic review
- benchmark reporting for time, model calls, tool calls, usage, cost, and accuracy

## Strict memo rules

The final memo must:

1. include title, author, date, and `Status: Draft` metadata;
2. include `TL;DR`, `Customer Problem`, `Current Evidence`, `Recommendation`, `Risks and Open Questions`, `Next Steps`, and `Sources` sections in that order;
3. cite at least two URLs that were actually read by `read_web_page`;
4. use numbered lists only;
5. rank list items from most important to least important;
6. contain no em dashes;
7. keep paragraphs short;
8. use blank lines between sections for readability.

The deterministic renderer guarantees the section skeleton, numbered lists, and
spacing. The deterministic audit rejects format violations. The LLM output
policy checks the semantic quality and source grounding.

## Run

Set a model provider key for the model you want to benchmark. For example, with
OpenAI:

```sh
export OPENAI_API_KEY=...
```

Set a Parallel key for web search and page reading:

```sh
export PARALLEL_API_KEY=...
```

Run the default benchmark:

```sh
TURNKIT_MODEL=gpt-5 \
TURNKIT_THINKING_EFFORT=medium \
bundle exec ruby examples/amazon_memo_writer/amazon_memo_writer.rb
```

Pass a different memo request as arguments:

```sh
TURNKIT_MODEL=gpt-5 \
TURNKIT_THINKING_EFFORT=medium \
bundle exec ruby examples/amazon_memo_writer/amazon_memo_writer.rb \
  "Write a memo on whether TurnKit should add a managed evaluations product."
```

The script prints a JSON benchmark block followed by the final memo.

## Accuracy checks

The benchmark reports 6 checks:

1. `searched_once`
2. `read_at_least_two_pages`
3. `finalized_with_submit_tool`
4. `strict_format_clean`
5. `cites_read_sources`
6. `audit_clean`

A successful strict run should show:

```json
"accuracy": {
  "score": 100.0,
  "passed": 6,
  "total": 6
}
```

## Pattern to copy

For exact output formats, avoid relying on prompts alone.

1. Ask the model to call a terminal submit tool with structured fields.
2. Validate those fields in Ruby.
3. Render the final Markdown in Ruby.
4. Run deterministic output audits first.
5. Use an LLM output policy only for semantic judgment.

This keeps TurnKit small while making strict output workflows reliable.
