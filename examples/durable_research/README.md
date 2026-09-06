# Durable research: the end-to-end reference application

A small **headless Rails application**, not a second workflow engine. It uses
TurnKit's real `ActiveRecordStore`, Active Job with **Solid Queue**, PostgreSQL,
three worker threads, and a recurring reconciliation job. No HTTP server or UI.

The application researches a fixed fictional product brief, dispatches two
independent reviewers, joins their answers, and validates/saves a report. The
same agents and tools run with deterministic fixture clients or real models.
It is not a live-web search demo; use `workflow_researcher` for that.

```text
submitter exits → PostgreSQL / Solid Queue → coordinator: read dossier
                                            ├→ evidence reviewer ─┐
                                            └→ risk reviewer ────┤
                          parent waits without a worker ←────────┘
                          validate → save report → completed
```

## Run in an Amp orb (no API keys or charges)

From the repository root, `.agents/setup` installs dependencies and prepares the
dedicated database. For an existing orb after pulling these changes:

```sh
.agents/setup
amp orb services ensure
bundle exec rake test:durable
```

Success prints JSON for all five scenarios and exits zero. Any unmet assertion
or timeout exits nonzero. The normal unit/integration suite remains separate:
`bundle exec rake test`. Do not run concurrent copies of the crash scenario:
it intentionally kills the example's worker process, including its other threads.

Outside an orb: install the root Gemfile dependencies and PostgreSQL, then run
`bundle exec ruby examples/durable_research/setup.rb`. It creates `turnkit_demo`
if needed (your database role needs CREATEDB, or an administrator can precreate
the database owned by your role). Start
`bundle exec ruby examples/durable_research/jobs.rb` in a separate terminal,
then run `bundle exec rake test:durable` from another terminal.

Setup is repeatable and does not drop data. It uses the actual TurnKit and Solid
Queue install templates to initialize an empty database, not a copied schema.
It is a bootstrap script, not a production migration/upgrade system. It accepts
only database names `turnkit_demo` or `turnkit_demo_<suffix>`; never point this
example at shared or production data.

## What the scenarios assert

Run individually with `bundle exec ruby examples/durable_research/scenarios.rb NAME`.

| Scenario | Executed checks |
| --- | --- |
| `normal` | A separate submitter process exits; two reviewer calls overlap; parent is waiting; second reviewer finishes first without releasing the parent; results retain call order; exactly one validated report is saved. |
| `conversation` | A second OS process reloads a conversation by ID, submits a follow-up, and receives an answer incorporating earlier history. |
| `messaging` | Duplicate message keys deliver once; a busy turn keeps its input snapshot; a subsequent turn consumes the delivery; an idle agent wakes; detached work produces a durable completion callback that wakes its recipient. |
| `recovery` | A real worker receives SIGKILL **after the report tool result is committed**; the supervisor replaces it; recurring reconciliation expires the claim and re-enqueues the turn; no second report or publication execution is created. |
| `media` | A background image tool generates then analyzes bytes, stores an image message, and returns a resolvable artifact reference through a completion callback. Fake mode uses placeholder bytes/analysis, not a real image or visual evaluation. |

Fixture barriers are database rows, not timing guesses. They let the verifier
observe concurrent work before releasing it. Recovery does not backdate
heartbeats, retry a queue failure manually, or execute the turn inline. It waits
for the actual recurring job. Solid Queue may retain a failed job record for the
killed process; the TurnKit turn is recovered through a new queue signal.

The crash check is deliberately **after a committed tool result**. It does not
promise exactly-once delivery for an external API call whose outcome was never
recorded. Such operations need application-owned idempotency/reconciliation.
Budget limits are configured; limit exhaustion, compaction and output-policy
repair remain covered by the library tests/other examples, not this demo.

## Submit now, inspect later

```sh
bundle exec ruby examples/durable_research/scenarios.rb submit
# Copy the returned turn_id, then use a new process:
bundle exec ruby examples/durable_research/scenarios.rb verify TURN_ID
```

Reports live in `demo_reports`; conversation/turn/tool/delivery/wait history lives
in `turnkit_*`; queue history lives in `solid_queue_*`. IDs in the JSON output
connect these records. Nothing is reset between runs. In an orb, inspect worker
failures with `amp orb service logs durable-research`.

## Opt-in live providers (paid)

Use a **separate database and worker** so a fake worker never consumes live jobs.
Export these in both submitter and worker environments:

```sh
export TURNKIT_DEMO_DATABASE_URL=postgresql:///turnkit_demo_live
export TURNKIT_DEMO_LIVE=1
export TURNKIT_MODEL=gpt-5.6-sol
# Supply OPENAI_API_KEY through your secret manager, not committed files.
bundle exec ruby examples/durable_research/setup.rb
```

Outside an orb, start `jobs.rb` in another terminal with those variables. In an
orb, use a separate managed service:

```sh
amp orb service start durable-research-live --command 'TURNKIT_DEMO_DATABASE_URL=postgresql:///turnkit_demo_live TURNKIT_DEMO_LIVE=1 bundle exec ruby examples/durable_research/jobs.rb'
bundle exec ruby examples/durable_research/scenarios.rb normal
bundle exec ruby examples/durable_research/scenarios.rb conversation
```

The live normal scenario verifies successful ordered reviews and publication;
only fake mode uses barriers to prove simultaneous execution. Models may fail
the requested tool protocol: that is a failed live check, not silently accepted
output. Registry lookup may make metadata requests for newer model IDs.
The example disables reasoning for `gpt-5.6-sol` tool-calling agents because
its Chat Completions endpoint requires `reasoning_effort: none` with tools.
RubyLLM provider errors, after its own retries, become `TurnKit::ModelError`
task failures rather than worker crashes retried by reconciliation.

For explicitly requested live image generation/review, also supply
`GEMINI_API_KEY` and set `TURNKIT_DEMO_MEDIA=1` in **both** environments (including
the managed service command), then run the `media` scenario. Models are
`gpt-image-2` and `gemini-3.8-flash`. Review actual output before trusting it.
The report and media agents each have a $2 observed-model-spend limit; this is
not a prepaid hard cap and does not prevent one request from exceeding it.
`all`, deterministic messaging barriers, and crash injection are fake-only.

## Code map

- `app.rb`: Rails boot, persistence models, queue adapter, agent registration.
- `agents.rb`: research/publication/media tools and fixture/live clients.
- `scenarios.rb`: independently executable assertions and submission commands.
- `config/queue.yml`, `config/recurring.yml`: actual workers and recovery cadence.
- `setup.rb`: idempotent database bootstrap using installed schemas.
