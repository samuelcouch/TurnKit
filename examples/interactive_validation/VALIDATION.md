# Interactive validation — 2026-09-09–10

## Verdict

The requested GPT-6 Astra/xhigh text-and-tool control scenarios passed with real
Rails 8.1/Active Job/Sidekiq workers and PostgreSQL. Recommend the existing TurnKit
RubyLLM adapter with explicitly pinned **RubyLLM 2.0.0.rc2**, selecting
`protocol: :responses`. The interim custom HTTP adapter was removed after this
SDK passed the same nine scenario types. Stable RubyLLM 1.16 compatibility remains;
the root development Gemfile was not upgraded to a prerelease.
The subsequently authorized native metadata fix also passed real Claude Opus
4.8/high and Gemini 3.1 Pro/high continuation/recovery on both SDK versions.
Applications choosing those validated native models can stay on stable 1.16.

This is ready for receiving-application integration, not an unconditional
production/release approval. Application ownership/authorization, approval policy,
custom-store status handling and worker rollout still belong to the application.
No push, merge, publication, release or production writes were performed.

## Transfer and execution provenance

The independent checkout started clean at the coordinator's exact
[source base](https://github.com/samuelcouch/TurnKit/commit/df2c69b43bd5b89ad908ce205ffccdcb7d1ba4ac).
The supplied 18-file final-content archive was verified against its path list and
SHA256 `c62fca1e765577dccc92306d929cd2decabc50334c03b39f5a31fb165d031bd8`,
extracted without unrelated overwrites, then removed. Baseline independent tests
passed: 278 runs, 1540 assertions, no failures/errors/skips.

Final environment: Ruby 3.3.10; Rails/ActiveRecord/ActiveJob 8.1.3.1; Sidekiq 8.1.7;
PostgreSQL 15.19; Redis 7.0.15; RubyLLM 2.0.0.rc2. The compatibility matrix also
used Rails/ActiveRecord/ActiveJob 7.2.3 and RubyLLM 1.16.0. Solid Queue 1.7.0 ran
the existing reference application's separate deterministic E2E scenarios.

## Exact model and actual accepted requests

The [OpenAI model card](https://developers.openai.com/api/docs/models/gpt-6-astra.md)
documents `gpt-6-astra` and `xhigh`; the
[migration guide](https://developers.openai.com/api/docs/guides/latest-model)
requires Responses for Astra function tools. A direct model lookup and bounded
Responses probe returned HTTP 200, `ASTRA_OK`, model `gpt-6-astra`, effort `xhigh`,
36 tokens. Probe response: `resp_02999ee27d13e4b5016aa1dbdc03bc87d0b49bee1675f77688`.
Provider credentials were available to Ruby independently of the Amp agent mode.

The SDK campaign recorded **28 accepted Responses requests**, all HTTP 200,
`status: completed`, exact model and effort. Usage: 3872 input + 1040 output = 4912
tokens, including 639 reasoning tokens within output. Estimated short-context
list-price cost: **$0.09072**. This includes a four-request `post_and_steer` rerun
after native-provider changes. Nonzero cache accounting is covered deterministically;
these live responses had no cache hits/writes.

The earlier custom OpenAI HTTP-adapter campaign used 28 requests/4790 tokens, estimated
$0.09474, including the defect reproduction/reruns. With the separately authorized
native campaigns below, total recorded usage is **86 requests/30,712 tokens/
$0.296048**, plus the 36-token/$0.00108 direct probe. These are estimates, not
invoice reconciliation. No alternative model was substituted for Astra.

Example stale-proposal evidence in the SDK campaign:

- Turn `turn_4629004311110c1233c3523f` received function call
  `call_jDDNds0rAPpCRPonlIuNl5Ru` in response
  `resp_01843943aa83761e016aa1e79463fc87d0900577eaba6344ab`.
- Revised response `resp_01843943aa83761e016aa1e796afd087d09f01547b02c89afa`
  accepted input ordered as original user → actual function proposal → skipped
  function output → first steering input → second steering input. No stale tool
  executed. Final output was `STEERED_37`.
- The receiving next turn was `turn_46d12a1ca19fb68e4fce5fcc`, used the executor's
  principal rather than the sender's and answered the posted `NEXT_2031` task.

## Live scenario index

Each name maps to executable assertions in `scenarios.rb`; all passed.

| Scenario | Root turn | Main evidence |
| --- | --- | --- |
| `post_and_steer` | `turn_4629004311110c1233c3523f` | Durable pending/applied delivery, ordered steering receipts, actual stale tool closed before user input, terminal retry, next-turn task, fresh-process cursor catchup. |
| `pause_model` | `turn_b6d1cdcb799e0d51aeb2c4c1` | Intent while response held, acknowledged claim release, candidate/usage preserved, no automatic wake, one request despite repeated resume. |
| `pause_tool` | `turn_88c39ccbbec7684d2a6d6513` | Two real proposals; first local read commits, second cancelled/skipped; revised request accepted and answer uses committed finding. |
| `approval_gate` | `turn_70f47d6617b38e56ea345d57` | Real queued job finishes without API call while paused before submission; posted input stays pending; resume executes original and followup. |
| `child_join` | `turn_39c32dafe4bda1a53a67025c` | Persistent join, subtree intent/ack distinction, cascade steering/resume, retained child finding, independent root excluded. |
| `retain_join` | `turn_088f52ca44b30a3cb337c0d1` | Child completes while parent remains paused; parent replans using finding after resume. |
| `launch_cascade` | `turn_8688449b778884161db06066` | `launch_agent` schedules an unjoined but parent-linked child; cascade resumes individually paused descendant. |
| `cancellation` | `turn_332f40570e9e4b34e4d2c846` | Worker finishes after real response; cancelled status and no output/input insertion remain fenced. |
| `recovery` | `turn_938d1f311860d62370955d30` | Worker exits 86 after real response/before persistence; public reconcile, acknowledged pause, replacement process; two provider calls, one steering message and unchanged first request receipt. |

Recovery worker PIDs were 16832 and 18369. Barriers use persisted rows to hold
genuine provider responses before the runtime observes them or to hold the local
read tool. They do not claim controls arrived while TCP bytes were in flight.
All 39 turns were terminal at the end of the initial Astra phase. The final
combined campaign has 56 terminal turns and no live turns; workers are stopped.
The export retains failed attempts rather than discarding them.

## Native provider metadata fix and live evidence

The existing adapter now preserves complete ordered Anthropic `content` blocks
and Gemini `candidate.content.parts` arrays in opaque provider parts. It retains
associated thinking/redacted/text/tool blocks and per-tool signatures, not just
signature strings. RC2 replays `raw_content`; 1.16 uses `Content::Raw`. Since
1.16 Gemini appends normalized calls after raw parts, that replay omits duplicate
normalized calls and maps tool result IDs to their original function names.
Nothing changes TurnKit's tool executor or public tool-call IDs.

All four final native runs passed with actual HTTP 200 responses and `high`
verified from the **sent HTTP request body**. Every replayed assistant block array
was checked for exact equality/order with the saved opaque data; real signatures
were observed without exporting their contents. Each run used six requests:
pause/steer during a read (one committed, one stale/skipped), next-turn reconnect,
and real worker death after a subsequent response, then reconstruction/replay with
the committed tool result, stable receipt and no repeated read tool.

| SDK / model | Pause/steer turn | Recovery turn |
| --- | --- | --- |
| 1.16 / Gemini 3.1 Pro Preview | `turn_c29b17538121852d4696492c` | `turn_34020ccb8058ee408efd7517` |
| 1.16 / Claude Opus 4.8 | `turn_f4e7a0c809d5b19b9c1836f6` | `turn_c55c65d1acb0bd6b6f9396f1` |
| RC2 / Gemini 3.1 Pro Preview | `turn_a0c7e3d1b55313dfcd0fbde7` | `turn_0e72d82f4bfe0ea48d1e64ee` |
| RC2 / Claude Opus 4.8 | `turn_82703794a7249c5fcef3da96` | `turn_66f49b84bbb944bc6ecdd4ff` |

The exact IDs were `gemini-3.1-pro-preview` and `claude-opus-4-8`, both present in
the installed registries; no model bypass or invented metadata was used. The first
six-request Gemini/1.16 attempt reached recovery but failed fresh-process JSON
parsing because an SDK deprecation warning went to stdout. Routing SDK warnings
to stderr fixed that. Inspection also found its output count already included
thinking, which TurnKit counted again. Native 1.16 usage normalization was fixed;
a six-request rerun checked exact totals. Those initial records remain historical.

Native campaign costs: Gemini/1.16 12 requests/9397 tokens/$0.046734 including the
first attempt; Claude/1.16 6/3801/$0.023225; Gemini/RC2 6/3987/$0.017124;
Claude/RC2 6/3825/$0.023505. No credential/model-access blockers occurred.
Registered native models are now live-proven choices; Opus 5 is not.

## Defects and unsuccessful attempts

Live validation found a runtime ordering defect: a destination post received
during an older turn preceded later steering chronologically. On the next turn,
that older steering could override the posted task. Provider projection now puts
deliveries at their first receiving turn's frozen-context boundary, while UI
sequence remains chronological. Memory/PostgreSQL regressions additionally check
a third-turn replay; the same live scenario passed after the fix on both adapters.

RubyLLM migration required public `generate`, renamed tools/schema/media APIs,
complete raw Responses replay (including phase and opaque reasoning), and exclusive
usage normalization. A new nonzero cost regression caught a mistaken compatibility
check: 1.16 already has `cache_read` getters but accepts `cached` constructor
keywords. The final implementation and both-version tests resolve it.

Two early SDK migration attempts failed before any provider call (missing/changed
SDK methods); their failed/cancelled records remain. The first SDK approval-gate
attempt failed an exact-output assertion because `Reply exactly FOLLOWUP.` yielded
`FOLLOWUP.`. Removing ambiguous prompt punctuation fixed the harness, not the
runtime. First three scenarios passed in that run; the remaining six were run
individually after the prompt correction to avoid wasteful repeated calls.

## SDK research and alternatives

Librarian verified the authoritative `v2.0.0.rc2` tag, not an ambiguous version-bump
commit or current main. At inspection, RubyGems latest stable was 1.16.0 and latest
prerelease 2.0.0.rc2. Relevant tagged sources:

- [Chat: protocol constructor, generate, with_tools, add_message](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc2/lib/ruby_llm/chat.rb).
  Repeated `with_tools` accumulates by name; `generate` does not execute tools.
- [Responses parsing/replay](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc2/lib/ruby_llm/protocols/responses/chat.rb).
  Default requests use `store: false` plus encrypted-reasoning inclusion. Supplying
  `raw_content` overrides reconstructed text/calls, avoiding duplicates and
  preserving item ordering/phase. Normalized `raw_content` alone is not sufficient
  for ordinary client tools; TurnKit preserves complete `message.raw.body.output`.
- [Tokens](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc2/lib/ruby_llm/tokens.rb)
  and [Cost](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc2/lib/ruby_llm/cost.rb).
  Input/cache buckets are exclusive; output includes thinking. TurnKit subtracts
  thinking for additive usage and reconstitutes inclusive output for SDK costing.

Separately inspected the actual installed `ruby_llm-1.16.0` gem:

- Its `Chat` constructor has no `protocol`; no public `generate`; OpenAI uses
  Chat Completions. Bundled registry lacks Astra, Opus 5 and GPT-5.6/-sol.
- Both `gemini-3.1-pro-preview` and `gemini-3.1-pro-preview-customtools` are present.
  Native Gemini implements `thinkingLevel`, message thinking and per-tool
  `thoughtSignature` replay. The standard Preview model subsequently passed the
  authorized native live campaign above; the customtools variant was not tested.
- Native Anthropic supports adaptive thinking and `output_config.effort`, gated
  by model reasoning metadata. `RubyLLM.chat(model: "claude-opus-5", provider:
  :anthropic, assume_model_exists: true)` bypasses lookup but does not add metadata:
  effort rendering raises `Anthropic thinking effort is not supported for
  claude-opus-5`. TurnKit chat also does not expose this bypass.
- The initial no-network fixture retained thinking/per-tool signatures in RubyLLM
  1.16, then lost them through TurnKit. That finding prompted the separately
  authorized native fix/live campaign above. Upgrading the SDK alone was not the
  fix; the durable adapter boundary needed complete raw-block replay.

## Reproduction and final checks

Use the exact environment/service commands in [README](README.md). The final
SDK continuation command (after first three scenarios passed) was:

```sh
export BUNDLE_GEMFILE="$PWD/examples/interactive_validation/Gemfile.ruby_llm2"
export TURNKIT_VALIDATION_WORKER=interactive-rubyllm2 TURNKIT_INTERACTIVE_LIVE=1
for scenario in approval_gate child_join retain_join launch_cascade cancellation recovery; do
  bundle exec ruby examples/interactive_validation/scenarios.rb "$scenario" || exit
done
```

Final `TURNKIT_TEST_DATABASE_URL=postgresql:///turnkit_test bundle exec rake test`:

| Gemfile | Result |
| --- | --- |
| Root (Rails 7.2 / RubyLLM 1.16) | 286 runs, 1666 assertions, 0 failures/errors/skips |
| `examples/interactive_validation/Gemfile` (Rails 8.1 / RubyLLM 1.16) | 286 runs, 1666 assertions, 0 failures/errors/skips |
| `examples/interactive_validation/Gemfile.ruby_llm2` (Rails 8.1 / RC2) | 286 runs, 1666 assertions, 0 failures/errors/skips |

`TURNKIT_DEMO_LIVE=0 TURNKIT_DEMO_DATABASE_URL=postgresql:///turnkit_demo bundle
exec rake test:durable` also exited zero with all five scenarios: normal,
conversation, messaging, real worker recovery and media (deterministic clients).
`git diff --check` passed. Regression tests cover authorization/preauthorization,
wall-time deadlines, budget retention, race/rollback/fencing, raw replay and usage.

Sanitized exports and full command logs are in `.amp/in/artifacts/`:
`final-interactive-evidence.json`, `final-rails72-rubyllm116-tests.log`,
`final-rails81-rubyllm116-tests.log`, `final-rails81-rubyllm2-tests.log`,
`final-solid-queue-tests.log`. Earlier `interactive-*` artifacts describe the
OpenAI HTTP prototype campaign; their test counts are historical, not final results.
`final-scenarios.json` records native runs and the final Astra rerun. The final
export includes all campaigns, distinguished by `provider_adapters`/`campaigns`.
It contains no credentials, auth headers, hidden reasoning or opaque signatures.

No UI was changed/rendered: both validation apps are headless. Live media,
automatic compaction/output-policy combinations, production topology and provider
outage behavior were not exercised. Pause is cooperative and wall-time deadlines
continue; cancelled requests can still be billed; recovery is not exactly-once.
Non-streamed native continuation is covered, not streaming or cross-provider
history conversion. Already-lost signatures in old stored history cannot be
recovered by this change. Synthetic tests cover redacted/multiple thinking blocks
and distinct per-tool signatures; not every native block variant occurred live.
No migration from the 0.6.0 schema is required. Applications/custom stores must
handle `paused`, and workers must be drained/upgraded together before controls
are enabled. Application approval ownership and existing release compatibility
requirements remain unchanged.
