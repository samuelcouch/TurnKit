# Typed evaluations, separate from chat

`Turn#internal_evaluation` runs bounded, named judgments from a tool or an
output-audit callable. It returns `EvaluationResult` (`answers`, `model`, `usage`,
`receipt_id`), not a chat `Result`. It neither appends messages nor changes model
history. Jev is not a conversational model, tool caller, reader, or writer.

## Cloudflare Jev

Configure credentials on the server, and register application audit callables at
boot in every worker. No Worker deployment, RubyLLM registration, or JavaScript
sidecar is required.

```ruby
jev = TurnKit::Adapters::CloudflareJev.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN")
)

# USD per million tokens. Confirm current account pricing before setting these.
# Cloudflare's catalog estimate on 2026-09-19, NOT an invoice guarantee:
TurnKit.cost_rates["cloudflare/typesafe/jev"] = { input: 0.042, output: 0 }

audit = lambda do |output, turn:|
  result = turn.internal_evaluation(
    evaluator: jev, model: "typesafe/jev", purpose: :evidence_support,
    policy_version: "support-v1", candidate: output,
    state: { source_context: "The pilot is limited to five stores.", finding: output },
    questions: {
      support: {
        type: "noul", instructions: "Does the original context support the finding?",
        criteria: { "true" => "Supported by the context", "false" => "Not supported" }
      },
      scope: {
        type: "choice", instructions: "What scope does the original context describe?",
        criteria: { pilot: "Limited pilot", general: "General rollout", other: "Neither" }
      },
      relevance: {
        type: "score", instructions: "How relevant is the context to the finding?",
        criteria: ["Unrelated", "Partly relevant", "Directly relevant"]
      }
    }
  )
  turn.output_metadata = { assessment: "shadow", receipt_id: result.receipt_id,
    returned_model: result.model, signals: result.answers }
  nil # Shadow records signals; it does not request a revision.
rescue TurnKit::EvaluationError => error
  turn.output_metadata = { assessment: "unassessed", reason: error.status }
  nil # Application decision: return baseline evidence when assessment is unavailable.
end

# Use this callable on the producing agent, alongside its existing strict schema.
# output_policy: audit, output_retries: 1
```

Inputs use Cloudflare's schema: state and instructions may be a string, object,
array, or null. Nested JSON can contain numbers and booleans. Questions are
independent; there are no answer-to-answer dependencies. Symbol hash keys are
normalized and object keys sorted before dispatch and hashing. Array order is
preserved (especially Score rubrics). No inner model-version parameter is sent.

- **Noul:** `{"type":"noul","noul":0.73}` — probability of yes, no separate confidence.
- **Choice:** selected permitted key, probability distribution, and confidence.
- **Score:** fractional rubric position, probability distribution, string-valued
  legend, and confidence. Levels start at zero.

The adapter checks exact question IDs/types, permitted options, probability and
confidence ranges, usage integers, and closed response objects. Distributions
must sum to one within 0.01 to allow rounding. Scores must lie within the supplied
rubric. It does not infer prose, repair malformed answers, or enforce undocumented
Cloudflare limits borrowed from TypeSafe's direct endpoint. Cloudflare's current
output schema requires string legend entries even for structured input criteria;
an incompatible provider response is `malformed`, not silently accepted.

## OpenRouter Jev (Decisions alpha)

`OpenRouterJev` uses **POST https://openrouter.ai/api/alpha/decisions**, with
`{model, state, questions}` and bearer authentication. It is not the chat endpoint
and does not use Cloudflare's `input` wrapper. It needs no SDK, RubyLLM model
registration, new agent harness, or migration. This follows OpenRouter's
[existing-harness integration guidance](https://github.com/OpenRouterTeam/skills/tree/main/skills/create-agent-tui).

```ruby
jev = TurnKit::Adapters::OpenRouterJev.new(
  api_key: ENV.fetch("OPENROUTER_API_KEY"),
  billing_identity: "desk-production" # Stable non-secret account/workspace label
)
# Listed USD/M on 2026-09-19; confirm current pricing. This is an estimate only.
TurnKit.cost_rates["openrouter/typesafe/jev-1.13"] = { input: 0.042, output: 0 }

audit = lambda do |output, turn:|
  # Application-owned helpers: locate original quotes in Ruby, bound the context,
  # and construct per-finding questions. Never call this from an AR callback.
  context = EvidencePolicy.located_context(output)
  result = turn.internal_evaluation(
    evaluator: jev, model: "typesafe/jev-1.13", purpose: :evidence_support,
    policy_version: "support-v1", candidate: output, state: context,
    questions: EvidencePolicy.questions(output), max_attempts: 1,
    before_dispatch: ->(turn:, model:, purpose:) {
      DeskBudget.check_quality_control!(turn, model: model, purpose: purpose)
    }
  )
  turn.output_metadata = { assessment: "shadow", receipt_id: result.receipt_id,
    returned_model: result.model, signals: result.answers }
  nil
rescue TurnKit::EvaluationError => error
  turn.output_metadata = { assessment: "unassessed", reason: error.status }
  nil
end
# source_reader: output_policy: audit, output_retries: 1
```

Use the app's 100% quality-control gate, not its discovery gate. For assist mode,
replace the successful `nil` with application-calibrated targeted violations only
after validating the returned model; the existing one-revision lifecycle handles
repair/reassessment. Leave unavailable evidence explicitly unassessed. Keep the
generated schema and Astra/Terra/Gemini roles unchanged.

The billing label is persisted in receipt identity, not sent to OpenRouter. Change
it when the billing account/workspace changes; credential rotation within the same
account need not invalidate receipts. Never put a credential in this label.
The identity also includes the exact endpoint and adapter schema version.
No attribution, routing, trace, user, or session headers/options are sent.
Account privacy/routing settings remain the application's responsibility; change
`policy_version` if a policy-relevant account configuration changes.

State/instructions cannot be null on this route. Explicit Noul criteria require
both true and false descriptions. TurnKit keeps its stricter supported subset:
Score requires at least two levels and string-valued returned legend entries.
OpenRouter marks Choice/Score confidence, distributions, and Score legend optional;
TurnKit deliberately **rejects missing fields as malformed**, rather than
inventing them or weakening shared answer validation. Extra provider envelope
fields (including `id` and `provider`) are ignored before closed answer validation;
requested route and returned model are retained in the existing receipt.

Valid `usage.cost` is preferred over configured rates, including a reported zero.
Absent cost uses the explicit route-keyed fallback above (or the configured cost
calculator); without either, cost remains unknown. Malformed answers retain valid
observed tokens and charges. If token counts themselves are invalid but a valid
charge is reported, the charge is retained without adding unvalidated tokens.
HTTP errors also retain reported usage when present. No provider error body is
logged. Nonretryable 400/401/402/403/404/413 errors are unavailable; 429 and 5xx
(including 524/529) are eligible for TurnKit's bounded opt-in retries. Transport
timeouts and 5xx remain uncertain, not zero-cost failures. Default attempts stay 1.

The [model page](https://openrouter.ai/typesafe/jev-1.13) lists 32K context and one
TypeSafe provider. The [Decisions schema](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request.md)
shows a dated returned model such as `typesafe/jev-1.13-20260917`; the requested
family is **not an immutable weights pin**. This alpha transport offers no assumed
redundant hosting, idempotency, retention/ZDR, or latency guarantees here.

With explicit spending permission and `OPENROUTER_API_KEY` configured server-side:

```sh
TURNKIT_LIVE_OPENROUTER_JEV=1 bundle exec ruby examples/open_router_jev_smoke.rb
```

This makes at most **one** small synthetic request with all three primitives,
checks supported versus unsupported claims and period/basis mismatch, and checks
receipt replay through a real Turn without another network dispatch. The producing
chat response is a local fixture. It prints validated answers/model, observed
usage/charge, fallback cost, semantic check results, and replay status. No paid CI,
private evidence, alternate provider, or automatic retry is involved. The $0.01
Turn budget is an admission check, not a provider-side hard cap; the tiny request
is estimated well below it at listed rates. Do not rerun after an uncertain error
without checking its outcome. Passing synthetic checks is not semantic calibration
or evidence of application savings.

Live check on 2026-09-19: one request returned `typesafe/jev-1.13-20260917`,
578 input tokens, 145 output tokens, and reported cost $0.000024276 (no unknown
charge). All strict fields were present. Supported/unsupported Noul values were
0.99/0.02, period was `fy2024`, basis was `adjusted`, and mismatch support score
was 0. All five synthetic checks passed; receipt replay made no second dispatch.

## Receipts and accounting

The operation requires an actively owned Turn execution. Calling the adapter
directly is possible for a smoke test, but bypasses Turn accounting and recovery.

1. Validate locally. Hash the actual normalized input, evaluator route/account/
   schema identity, requested model, purpose, policy version, explicit candidate,
   current output text/data, timeout, and attempt limit.
2. Under the root execution lock, check ownership and persisted root budgets,
   then persist an attempt ID marked `uncertain` **before** network dispatch.
3. Release the lock before HTTP. After a response, atomically commit its receipt,
   observed usage, and configured cost under the same ownership fence.
4. Return completed identical receipts without another network call or accounting
   increment. Changed candidates, policies, or requests get different identities.

Receipts live in `options["state"]["evaluations"]`; inspect a copy through
`turn.evaluation_receipts`. No new table or migration is needed. Source state and
questions are hashed, not copied into receipts or evaluation events. Answers and
compact metadata are persisted; avoid putting sensitive text into question IDs
or option labels. Existing chat events retain their existing behavior.

`evaluation.requested`, `evaluation.completed`, and `evaluation.failed` expose
receipt/attempt IDs, requested/returned model, question count, timing, usage,
cost, and safe status/HTTP code. They do not include source text or bearer tokens.
Events are notifications, not a durable exactly-once delivery channel.

The cost lookup key is **`cloudflare/typesafe/jev`** or
**`openrouter/typesafe/jev-1.13`**, never the producing agent's model or an unrelated
RubyLLM model. `TurnKit.cost_calculator` can also price these keys.
Returned model versions are retained separately. Each observed attempt's
usage is counted, including a malformed response with valid usage. Unknown usage
or pricing is not fabricated: attempt `cost` is null, and turn/run/conversation
`Cost#unknown?` is true with `total == nil` if any evaluation attempt has unknown
cost. The persisted numeric turn cost remains the **known-cost subtotal** used by
existing root budget checks. Budgets cannot bound an unreported provider charge
or reserve future concurrent spend; applications needing a hard billing ceiling
must also enforce a provider/account limit or their own reservation policy.

## Recovery, retries, and controls

The default `max_attempts: 1` deliberately does not replay an unknown network
execution after a worker crash. The application can return unassessed evidence.
Opt into `max_attempts: 2` or `3` for bounded transient retries, including uncertain
attempts left by an old worker. The cap includes all persisted attempts for the
same receipt, not just attempts in the current process. Non-transient failures
and malformed responses are not retried. Retry-After (seconds or HTTP date) takes
precedence over exponential full jitter. Cloudflare quota exhaustion is not
treated as temporary capacity pressure. Net::HTTP's implicit retries are disabled.

`timeout: 30` bounds each invocation, including HTTP and retry waits; the root
deadline also applies across recovery. Before each dispatch/retry, TurnKit checks
the root spend/depth/deadline, ownership, pause request, `Authorization` action
`:evaluate`, and an optional `before_dispatch` callable:

```ruby
before_dispatch: ->(turn:, model:, purpose:) {
  # Raise an application/TurnKit error to deny transport. Return value is ignored.
  DeskBudget.check_quality_control!(turn, model: model, purpose: purpose)
}
```

An already-completed receipt can be read without another spend check inside an
admitted running execution. This does not waive the outer runtime's normal
phase-admission, timeout, or cancellation rules. A late response may still have
been billed: while ownership remains valid its usage is recorded, but a deadline
error prevents using it in that invocation. Revoked/cancelled workers cannot
commit a response; their persisted attempt remains uncertain. Cancellation
cannot recall a sent HTTP request.

`EvaluationError#status` distinguishes `unavailable`, `malformed`, `uncertain`,
`interrupted`, and `in_progress`; `http_status`, `retryable?`, and `retry_after`
provide safe transport diagnostics. `InputError` means local validation failed.
`BudgetError`, `AuthorizationError`, and `LostClaim` are not evaluation failures
to swallow as successful assessments. Never perform network evaluation from an
ActiveRecord callback or wrap a model/evaluation call in an application transaction.

**No provider idempotency is promised.** A crash after provider execution but
before the atomic local commit can cause paid duplication if retries are enabled.
Known committed accounting is applied once; unobserved attempts remain unknown.
Audit callables must be replayable: compute assessment metadata and return
violations, rather than performing non-idempotent downstream actions. Existing
revision-message/count/phase writes remain atomic.

## Applying this to a source-reader child

Keep Ruby's deterministic quote matching against immutable original sources.
Build bounded context around located quotations in the output-audit callable,
then ask narrow questions about individual findings, period/unit/basis support,
omitted qualifications, and relevance. Do not send whole filings or analyst
opinions. Keep exact matching, arithmetic, dates, authorization, and action policy
in application code. State can contain adversarial instructions.

For Thanos99, Astra still interprets and synthesizes; Terra still reads sources
and produces the strict evidence schema. Jev is a separate quality-control
expense, not a new chat model or tool available to Terra. Apply the app's 100%
quality-control budget boundary through `before_dispatch`, not its 80% discovery
gate. TurnKit has no built-in reserve percentages.

- **Off:** do not call the evaluator.
- **Shadow:** save signals with `turn.output_metadata=`, return no violations.
- **Assist:** map calibrated signals to specific `OutputAudit::Violation`s;
  configure the producing agent with `output_retries: 1`. This yields at most one
  producing-model repair and one reassessment of the revised candidate. Keep
  `max_attempts: 1` for at most two Jev network attempts. If a repair produces an
  identical candidate, its identical receipt can be reused.

Return no violation when unavailable if baseline evidence is acceptable, but
include an explicit unassessed status. Disable automated repair for returned
models the application has not validated. Low confidence alone is not a repair
instruction. Choice/Score confidence measures distribution concentration, not
the probability that the workflow is correct. Type safety is not factual truth.

Runtime-owned `output_metadata` is separate from model-generated `output_data`.
It is reset when a new model candidate is persisted, and the audit sets it for
that candidate. `SubAgentTool.result` includes it only when present, using the
same serializer inline and in background joins. Parents wait through the child's
audit/revision phase and receive only the final compact envelope. Keep metadata
small; it is model-visible when returned to the parent. Output schemas and prompt
prefixes need no changes.

## Provider evidence and live verification

Reviewed 2026-09-19:

- [Cloudflare Jev](https://developers.cloudflare.com/ai/models/typesafe/jev/),
  [input schema](https://developers.cloudflare.com/ai/models/typesafe/jev/schema-input.json),
  [output schema](https://developers.cloudflare.com/ai/models/typesafe/jev/schema-output.json),
  [catalog source](https://github.com/cloudflare/cloudflare-docs/blob/production/src/content/catalog-models/typesafe-jev.json).
  POST `/client/v4/accounts/{account_id}/ai/run` with `{model: "typesafe/jev", input: {state, questions}}`.
  Catalog: `jev-latest`, 32,000-token context, `supports_async: false`, `zdr: false`.
  No promised version pinning, ZDR, cache discount, latency SLA, or idempotency.
- Cloudflare's Jev examples show a bare model result; its
  [REST guide](https://developers.cloudflare.com/workers-ai/get-started/rest-api/)
  shows the standard `success/result/errors/messages` envelope. Both are validated;
  actual account wire behavior requires the live smoke test below.
- [TypeSafe models](https://docs.typesafe.ai/models),
  [primitives](https://docs.typesafe.ai/primitives),
  [confidence](https://docs.typesafe.ai/confidence), and
  [Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
  describe probabilistic judgments, not browsing, image inspection, generation,
  or reliable arithmetic/date comparisons. Direct endpoint limits are not the
  Cloudflare transport contract.
- [Extraction cascade cookbook](https://docs.typesafe.ai/cookbooks/sde_cascade):
  vendor-run, older Jev 1.12, explicitly hard-coded canonical bad extraction,
  historical cost chart. Useful support for per-field assessment, not evidence
  of savings or a transferable acceptance threshold in this application.

After obtaining explicit permission for a small paid call and configuring the two
Cloudflare environment variables, run:

```sh
TURNKIT_LIVE_EVALUATION=1 bundle exec ruby examples/structured_evaluation_smoke.rb
```

This sends one public synthetic state and three questions, with no retries or
other providers. It prints only validated model/answers/usage. It verifies the
transport/schema, not semantic calibration or production savings. Automated
tests make no provider calls.
