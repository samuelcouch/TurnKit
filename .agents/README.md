# TurnKit in Amp orbs

`.agents/setup` installs a checksum-pinned Ruby 3.3.10 binary, Bundler 2.5.22,
the Gemfile dependencies, and PostgreSQL 15 with local `turnkit_test` and
`turnkit_demo` databases. It prepares the durable example's schema without
starting workers or running model calls.
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
bundle exec rake test:durable
```

Postgres and the fake-mode durable example workers are supervised through
`.amp/services.yaml`, with no public portal.
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

Non-secret configuration:

- `TURNKIT_MODEL`: choose a model actually enabled on your provider account for
  examples that read this setting. It is not a global environment switch in the
  library; application code configures `TurnKit.default_model`.
- `TURNKIT_MEDIA_MODEL`: media example's model (default `gemini-3.8-flash`).
- `TURNKIT_IMAGE_MODEL`: image example's OpenAI model (default `gpt-image-2`).
- `TURNKIT_MAX_SPEND`, `TURNKIT_MAX_ITERATIONS`, `TURNKIT_MAX_TOOL_EXECUTIONS`:
  example-specific limits. Consult each example's README; external research
  service charges are not necessarily included in model spend accounting.
- `PARALLEL_TASK_PROCESSOR`, `PARALLEL_DEEP_PROCESSOR`,
  `PARALLEL_FINDALL_GENERATOR`: optional research tier overrides. Polling/timeout
  defaults are already supplied by the examples and need not be set in Amp.

Live examples refresh RubyLLM's in-memory registry if the selected model is
missing from the bundled catalog. This uses configured provider keys for model
metadata, not inference. See `examples/README.md` for task-specific defaults.

## Live checks and limits of "fully end to end"

With the relevant project secrets and explicit approval for paid API calls:

```sh
bundle exec ruby examples/media_analysis/gemini_3_flash_view_media.rb
bundle exec ruby examples/workflow_researcher/workflow_researcher.rb
```

Read each example's inputs and cost notes before running larger research tasks.
The image-generation example uses RubyLLM directly with `OPENAI_API_KEY`:
`bundle exec ruby examples/image_generation/gpt_image_2.rb`.

The optional Codex adapter additionally requires the Codex CLI and per-thread
`codex login --device-auth` (or supported API-key login). `CODEX_COMMAND` can
override its executable path. Install the CLI before using this adapter; never
authenticate it in setup or snapshot a user's login. An OpenAI key in Amp alone
does not satisfy this adapter's `codex login status` check.

The headless Rails application in `examples/durable_research` supplies real
Solid Queue workers, PostgreSQL persistence, recurring reconciliation, and
assertion-based E2E scenarios. Its README documents an isolated opt-in live run;
the declared orb worker always uses fake providers, even when API keys exist.
Oracle/Librarian repository credentials and artifact storage credentials
depend on the tools/storage the host app supplies; TurnKit has no built-in env
variables or bundled GitHub/attachment service for those integrations.

After changing Amp project secrets for an existing orb, use
`amp orb restart-processes` to refresh them (this restarts managed processes).
Never print secret values to verify availability.
