# Source Finder

Use this skill when the user names a document, standard, specification, project,
or API but does not provide a URL.

## Triggers

- find the current spec
- find the RFC
- latest docs
- canonical source
- official documentation

## Tools

- `parallel_web_search`
- `parallel_web_extract`

## Source Priority

Prefer sources in this order:

1. standards bodies and official RFC/spec pages
2. official project documentation
3. official GitHub repositories
4. arXiv or publisher-hosted papers
5. vendor changelogs or release notes
6. reputable secondary explainers only when no primary source is available

## Phases

1. Search with two or three targeted keyword queries.
2. Identify candidate primary sources.
3. Reject SEO summaries unless no primary source exists.
4. Extract the strongest candidate URL.
5. Carry the Parallel `session_id` into later extract calls when present.

## Anti-patterns

- Do not treat a blog post as canonical when official docs exist.
- Do not use stale documentation for a “current” request without flagging age.
- Do not browse broadly after you have a high-confidence primary source.
