# Technical Explainer

Use this skill when the user asks to explain a paper, RFC, technical spec,
standard, API documentation page, changelog, or other technical source material.

## Triggers

- explain this paper
- explain this RFC
- summarize this spec
- what should engineers know about this?
- read this technical document
- turn this into an implementation brief

## Tools

- `parallel_web_search`
- `parallel_web_extract`
- `save_source_document`
- `save_concept`
- `save_implementation_concern`
- `save_research_brief`

## Phases

1. Identify whether the user provided a URL.
2. If a URL exists, gather source text with `parallel_web_extract`.
3. If no URL exists, call `parallel_web_search` to find the canonical source first.
4. Prefer primary documents over summaries, blog posts, or commentary.
5. Save source documents that support the answer, including relevant excerpts when available.
6. Extract only concepts that matter to the requested audience.
7. For a full example run, save 2-4 important concepts with `save_concept`.
8. For a full example run, save 2-4 implementation risks or caveats with `save_implementation_concern`.
9. Produce and save a practical implementation brief with `save_research_brief`.

## Output Format

Use this shape unless the user asks for something else:

```text
## What this is
## Why it matters
## Key concepts
## Implementation implications
## Risks and caveats
## Open questions
## Sources
```

## Anti-patterns

- Do not produce a generic summary.
- Do not reject a provided URL because it seems unrelated to the requested audience; explain the actual document and adapt implications to the audience.
- Do not omit implementation consequences.
- Do not cite secondary summaries when a primary source was available.
- Do not claim certainty where the source is ambiguous.
- Do not explain every detail; prioritize what matters to the requested audience.
- Do not invent guarantees, API behavior, benchmark results, or adoption claims.
