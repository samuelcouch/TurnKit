# TurnKit in Amp orbs

`.agents/setup` installs a checksum-pinned Ruby 3.3.10 binary, Bundler 2.5.22,
the Gemfile dependencies, and PostgreSQL 15 with a local `turnkit_test` database.
It reuses installed packages and gems on warm snapshots. Ruby's prebuilt x64
Ubuntu 22.04 distribution is verified to run on Debian 12; its installation
prefix must not be relocated. Gemfile.lock is intentionally ignored by this gem
repository: Bundler reuses a snapshot's lockfile and resolves one on a cold orb.

Login shells in this checkout receive Ruby on PATH, BUNDLE_PATH, and
`TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test` unless explicitly overridden.
Do not override that URL with production/shared data: database tests rebuild
their namespaced tables. No database password or external database is needed.

After activation, run:

```sh
amp orb services ensure
bundle exec rake test
```

Postgres is supervised through `.amp/services.yaml`, with no public portal.
It uses local peer authentication and disables fsync/synchronous commit for
disposable test data. No resume hook is needed: there are no authentication or
repair steps, and Amp owns the declared service lifecycle. Setup never performs
live model calls, logs in to providers, or puts user credentials in a snapshot.

## Amp environment variables and credentials

Add credentials as **Amp project secrets**, not tracked files or setup-script
literals. No secrets are required for the automated test suite (including real
Postgres concurrency and worker-death tests). Live provider coverage is separate:

| Secret | Needed for |
| --- | --- |
| `OPENAI_API_KEY` | OpenAI text/tool/structured-output calls; OpenAI image models if enabled on the account. |
| `GEMINI_API_KEY` | Gemini text, image generation/editing, and the media-analysis smoke example. |
| `ANTHROPIC_API_KEY` | Anthropic adapter coverage; optional if only testing another provider. |
| `OPENROUTER_API_KEY` | OpenRouter adapter coverage; optional otherwise. |
| `PARALLEL_API_KEY` | Live search/extract/task research examples; account needs access to the selected Task/FindAll/Entity APIs. |
| `HUNTER_API_KEY` | Optional standalone shared Hunter client coverage; not required by the main test suite. |
| `APOLLO_API_KEY` | Optional standalone shared Apollo client coverage; account permissions/credits must cover tested endpoints. |

Non-secret configuration:

- `TURNKIT_MODEL`: choose a model actually enabled on your provider account for
  examples that read this setting. It is not a global environment switch in the
  library; application code configures `TurnKit.default_model`.
- `TURNKIT_MEDIA_MODEL`: media example's model (default `gemini-3-flash-preview`).
- `TURNKIT_MAX_SPEND`, `TURNKIT_MAX_ITERATIONS`, `TURNKIT_MAX_TOOL_EXECUTIONS`:
  example-specific limits. Consult each example's README; external research
  service charges are not necessarily included in model spend accounting.
- `PARALLEL_TASK_PROCESSOR`, `PARALLEL_DEEP_PROCESSOR`,
  `PARALLEL_FINDALL_GENERATOR`: optional research tier overrides. Polling/timeout
  defaults are already supplied by the examples and need not be set in Amp.

The technical-explainer example's auto-selection checks `GOOGLE_API_KEY`, while
the adapter authenticates with `GEMINI_API_KEY`. For Gemini, set `TURNKIT_MODEL`
explicitly and supply `GEMINI_API_KEY`; don't rely on that legacy selector.

## Live checks and limits of "fully end to end"

With the relevant project secrets and explicit approval for paid API calls:

```sh
bundle exec ruby examples/media_analysis/gemini_3_flash_view_media.rb
bundle exec ruby examples/workflow_researcher/workflow_researcher.rb
```

Read each example's inputs and cost notes before running larger research tasks.
The image-generation example uses an external `generate-image` executable not
distributed by this repository; credentials alone cannot make it work. Test the
standard `TurnKit::Adapters::RubyLLM` image path directly, or provide that CLI.

The optional Codex adapter additionally requires the Codex CLI and per-thread
`codex login --device-auth` (or supported API-key login). `CODEX_COMMAND` can
override its executable path. Install the CLI before using this adapter; never
authenticate it in setup or snapshot a user's login. An OpenAI key in Amp alone
does not satisfy this adapter's `codex login status` check.

Real durable queue-backend E2E additionally needs a host Rails application with
the generated TurnKit migrations, registered agents, a persistent Active Job
backend (e.g. Solid Queue), workers, and recurring reconciliation. This gem's
Postgres tests exercise the runtime but do not provision a deployed host app.
Likewise, Oracle/Librarian repository credentials and artifact storage credentials
depend on the tools/storage the host app supplies; TurnKit has no built-in env
variables or bundled GitHub/attachment service for those integrations.

After changing Amp project secrets for an existing orb, use
`amp orb restart-processes` to refresh them (this restarts managed processes).
Never print secret values to verify availability.
