# Recipe builder: skills, live context, research and JSON

A real API example that turns a cook's request into a source-grounded recipe.
It uses Claude Sonnet 5 with **high thinking** for both builder and reviewer,
and Parallel for web search and page extraction. No fake providers in the CLI.

```sh
# Configure ANTHROPIC_API_KEY and PARALLEL_API_KEY through Amp secrets.
bundle exec ruby examples/recipe_builder/recipe_builder.rb \
  "Build a vegetarian lemon-chickpea and spinach skillet for 2 people, ready in 30 minutes. No peanuts. Use metric quantities." \
  > recipe.json
```

No argument uses that request. Stdout is only the recipe JSON; stderr reports
verification checks, tool names, request observations, research notes, reviewer
critiques, token usage and observed cost (not model thinking traces).
`TURNKIT_MODEL` selects another model supporting high thinking **with tools**.
There is no silent downgrade to a non-thinking model. In particular, Sol's
Chat Completions tool path with reasoning enabled is not appropriate here.

## What happens

1. Inject the cook's requirements through agent-scoped `context_contributors:` rather
   than copying them into the user message.
2. Present only skill metadata initially. The model calls `load_skill` to read
   [`building-recipes`](skills/building-recipes/SKILL.md).
3. Search the web and read two or three recipe sources using Parallel.
4. Record a concise adaptation note. The updated notebook is injected into the
   next model request as untrusted live context.
5. Delegate the draft and evidence to a separate, tool-free `recipe_reviewer`.
   The builder receives its critique and revises the recipe. This is an explicit
   research/review dialogue, not a dump of private chain-of-thought.
6. Call a terminal structured submit tool. It checks required fields, positive
   servings/time, nonempty ingredients/steps, completed skill loading/review,
   research notes, and at least two distinct URLs from successful page extracts.

The JSON contains `title`, `servings`, `total_minutes`, `ingredients` (name and
quantity), `steps`, `sources` (URL and what it supports), and `assumptions`.

## Verification and limits

The CLI checks successful outgoing model requests for loaded skill content,
injected requirements, updated notebook context, and high thinking configuration.
It also requires search and a completed reviewer. Checks fail loudly rather than
printing a successful recipe when the demonstration did not exercise its features.
The skill-specific `Adaptation:` requirement is checked at submission.

The default observed-model-spend limit is $1.50 (`TURNKIT_MAX_SPEND`), shared with
the reviewer; two searches, two source-read batches and two reviews are allowed.
This is not a prepaid cap: a single request can exceed it, and Parallel charges
are not included. Model access and real web extraction failures are not hidden.

State is memory-only and contributors belong to this agent, without mutating
global configuration. This standalone example is not a durable
worker demo. Run `bundle exec ruby -Itest test/recipe_builder_test.rb` for unpaid
regressions; those use fake clients, unlike the CLI.

Citation checks establish source provenance, not factual correctness. Recipes
are model adaptations, not kitchen-tested; dietary/allergen suitability and food
safety still require human judgment. No nutrition or allergy certification is
claimed.
