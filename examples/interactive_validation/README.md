# Live interactive validation

This headless Rails app uses real PostgreSQL, Active Job and Sidekiq workers,
and **paid model API calls**. It never uses trading, publication, or external-write
tools. The only research tool reads the adjacent local `evidence.txt` fixture.
Do not point it at application databases or production Redis.

The default campaign requires exactly `gpt-6-astra` with `reasoning.effort: "xhigh"`.
The client checks both the outgoing parameters and returned provider metadata.
The [model card](https://developers.openai.com/api/docs/models/gpt-6-astra.md)
documents this mapping. OpenAI's [migration guide](https://developers.openai.com/api/docs/guides/latest-model)
requires Responses for Astra tools. Amp agent access is not sufficient: this app
needs `OPENAI_API_KEY` in the worker's environment.

The existing `TurnKit::Adapters::RubyLLM` explicitly selects `protocol: :responses`
with **RubyLLM 2.0.0.rc2**, pinned in `Gemfile.ruby_llm2`. It calls the public
single-response `generate`; TurnKit alone executes tools. There is no separate
HTTP adapter. The root Gemfile keeps stable RubyLLM 1.16/Rails 7.2 compatibility;
this directory's `Gemfile` supports native 1.16 validation with Rails 8.1.
Each alternate Gemfile has a lockfile. Adopting a prerelease is an application
decision; a future stable release needs regression/live validation again.

## Reproduce in an orb

Commands assume the repository root. Install Redis 7+ if absent; the repository
setup supplies Ruby and PostgreSQL. Only run the live commands with permission
to use the configured provider account. The worker and controller must both
have the live flag; no credential value belongs in a command or tracked file.

```sh
export PATH=/opt/hostedtoolcache/Ruby/3.3.10/x64/bin:$PATH
export BUNDLE_PATH="$HOME/.cache/turnkit/bundle"
export BUNDLE_GEMFILE="$PWD/examples/interactive_validation/Gemfile.ruby_llm2"
bundle install
# Start the repository PostgreSQL service if needed.
amp orb services ensure
sudo -u postgres createdb -O user turnkit_interactive_validation
bundle exec ruby examples/interactive_validation/setup.rb
amp orb service start interactive-redis --command 'redis-server --bind 127.0.0.1 --port 6380 --save "" --appendonly no'
amp orb service start interactive-rubyllm2 --command 'env PATH=/opt/hostedtoolcache/Ruby/3.3.10/x64/bin:$PATH BUNDLE_PATH=/home/user/.cache/turnkit/bundle BUNDLE_GEMFILE=/home/user/workspace/repo/examples/interactive_validation/Gemfile.ruby_llm2 TURNKIT_INTERACTIVE_LIVE=1 bundle exec sidekiq -r ./examples/interactive_validation/app.rb -q interactive_validation -c 4 -e test'
TURNKIT_VALIDATION_WORKER=interactive-rubyllm2 TURNKIT_INTERACTIVE_LIVE=1 bundle exec ruby examples/interactive_validation/scenarios.rb all
bundle exec ruby examples/interactive_validation/export.rb > /tmp/interactive-evidence.json
amp orb service stop interactive-rubyllm2
amp orb service stop interactive-redis
```

Use a new empty isolated database for an entire validation run. Setup preserves
existing data. The harness refuses further requests after 30 RubyLLM 2 responses
in that database (legacy native-adapter evidence is excluded). Concurrent in-flight
calls may exceed this by worker concurrency.
Each request allows at most 1,200 output tokens, and runtime limits are six
iterations/tools and $2 per root. These are cooperative limits, not a hard
provider billing cap. Export evidence before intentionally resetting disposable
data. Do not clear data merely to bypass the call cap.

`scenarios.rb` accepts individual scenario names as well. The recovery scenario
exits the actual worker process with code 86, advances reconciliation eligibility
through the public `before:` argument, and restarts the supervised service named
`interactive-sidekiq` (`TURNKIT_VALIDATION_WORKER` can name another orb service).
It does not simulate a process restart or promise exactly-once API execution.

## Native Claude and Gemini

Run only one worker profile at a time: profiles share the isolated queue and
registered agent names. Stop the Astra worker before starting a native worker.
Set `TURNKIT_VALIDATION_PROVIDER=anthropic` or `gemini` in **both worker and
controller**. These select `claude-opus-4-8`/`high` or
`gemini-3.1-pro-preview`/`high`; no model bypass or fallback is used. Supply
`ANTHROPIC_API_KEY` or `GEMINI_API_KEY` through the environment, never command text.

```sh
# Use Gemfile for 1.16, or Gemfile.ruby_llm2 for RC2. Start Redis as above.
export BUNDLE_GEMFILE="$PWD/examples/interactive_validation/Gemfile"
amp orb service start native-validation --command 'env PATH=/opt/hostedtoolcache/Ruby/3.3.10/x64/bin:$PATH BUNDLE_PATH=/home/user/.cache/turnkit/bundle BUNDLE_GEMFILE=/home/user/workspace/repo/examples/interactive_validation/Gemfile TURNKIT_VALIDATION_PROVIDER=gemini TURNKIT_INTERACTIVE_LIVE=1 bundle exec sidekiq -r ./examples/interactive_validation/app.rb -q interactive_validation -c 4 -e test'
TURNKIT_VALIDATION_PROVIDER=gemini TURNKIT_VALIDATION_WORKER=native-validation TURNKIT_INTERACTIVE_LIVE=1 bundle exec ruby examples/interactive_validation/scenarios.rb native
amp orb service stop native-validation
```

The native scenario performs six requests: pause/steering during a read tool,
next-turn reconnect and worker death after a committed tool and subsequent real
response. It checks actual request-body effort, returned model, real opaque
signatures, exact ordered replay, usage totals and unchanged recovery receipts.
The per-provider/per-SDK cap is 12 recorded responses. SDK warnings go to stderr
so fresh-process JSON snapshots remain parseable. Native failure telemetry records
HTTP status/class, not provider bodies. Exports retain usage/cost estimates per
campaign; opaque content is never exported. Streaming and cross-provider history
conversion are not covered.

## What the assertions exercise

| Scenario | Live assertions |
| --- | --- |
| `post_and_steer` | Destination post, pending→applied receipt, sender vs executor identity, two ordered steering receipts, actual stale tool proposal skipped, provider accepts repaired continuation, next-turn task, fresh-process cursor catchup without provider parts. |
| `pause_model` | Pause intent while request result is held; claim release only at acknowledgment; candidate and usage preserved; reconciliation cannot unpause; repeated resume does not repeat the request. |
| `pause_tool` | Two actual tool proposals, first read committed during pause, second skipped after steering, provider accepts both result messages before revised input. |
| `approval_gate` | Pause before submission; actual Sidekiq job completes without a provider call; post stays pending; resume executes original and then posted work. |
| `child_join` | Parent releases worker for a real child; cascade intent vs whole-subtree acknowledgment; persistent wait, child findings and parent replanning; independent root excluded. |
| `retain_join` | Child completes while parent remains paused; resume retains findings and replans. |
| `launch_cascade` | `launch_agent` creates parent-linked but unjoined child; cascade resumes even an individually paused descendant. |
| `cancellation` | Cancellation wins over pending pause/steering; after the worker finishes, its late real response is fenced and no output published. |
| `recovery` | Actual worker death after response receipt but before persistence; reconciliation acknowledges pending pause; replacement process repeats request without duplicating steering or changing its first request receipt. |

Barriers are persisted in `iv_barriers`; they hold a genuine provider response
inside the adapter before the runtime sees it, or hold a read-only tool. They do
not guarantee insertion while TCP bytes are in flight. `iv_evidence` retains
sanitized request/response IDs, exact model/effort, usage, tool IDs, public test
inputs and worker PIDs. It never stores credentials, auth headers, reasoning text
or encrypted reasoning. Runtime message rows separately retain opaque replay
parts; the export uses the authorized UI projection rather than dumping them.

The normal test suite additionally checks authorization denial/preauthorization,
wall-time deadline exhaustion, iteration limits, concurrent claims/resume,
rollback, and fencing with deterministic clients under memory and PostgreSQL:

```sh
# Rails 8.1 + RubyLLM 2.0.0.rc2 (using BUNDLE_GEMFILE above):
TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test bundle exec rake test
# Rails 8.1 + stable RubyLLM 1.16:
BUNDLE_GEMFILE=examples/interactive_validation/Gemfile TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test bundle exec rake test
# Root Rails 7.2 + stable RubyLLM 1.16:
env -u BUNDLE_GEMFILE TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test bundle exec rake test
```

Live coverage does not validate an application's approvals, custom stores,
production worker topology, media providers, or automatic compaction/output-policy
calls combined with these scenarios. Update application handling of `paused` and
drain/upgrade all workers together. No migration from the 0.6.0 schema is needed.
See [validation evidence](VALIDATION.md) for the executed campaign, SDK research,
failed attempts, version-specific limitations and readiness conclusion.
