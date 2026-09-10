# Interactive background research

Use submitted turns (`perform_later`) for worker-free suspension and durable
recovery. Register every agent in web and worker processes and configure a
persistent Active Job backend. TurnKit owns execution; the application owns
owner authorization, approvals, research records, and publication decisions.

## Public controls

```ruby
turn = TurnKit.load_turn(research.turn_uid)
conversation = TurnKit.load_conversation(research.conversation_uid)
principal = { "user_id" => current_user.id } # authenticated application data

# Durable next-turn input; does not change the current turn's frozen context.
delivery = conversation.post("Compare peers next", key: request_uuid, principal: principal)
receipt = conversation.input_status(delivery.fetch("id"), principal: principal)
# receipt: delivery fields, status: pending/applied, application: nil or
# { "turn_id" => ..., "request_id" => ... }

# Revise this turn before further planned work. Returns an array of receipts
# (one for the target; one per affected turn with descendants: :cascade).
inputs = turn.steer!("Prioritize debt maturities", key: request_uuid,
  principal: principal, descendants: :cascade)

turn.pause!(principal: principal, descendants: :cascade)
state = turn.control_state(principal: principal)
# state["controls"]["pause_requested"] means requested, NOT acknowledged.
# state["status"] == "paused" means this turn has released its claim.

turn.resume!(principal: principal, descendants: :cascade)
turn.cancel!(principal: principal, descendants: :cascade) # terminal, not pause
```

`pause!`, `resume!`, `steer!`, and `control_state` also exist on `Run`.
`pause!`/`resume!` return the reloaded receiver. Their default is
`descendants: :retain`; `:cascade` follows existing parent-turn lineage,
matching cancellation. Repeated resume is safe; competing jobs still claim
the turn only once. Resume before acknowledgment retracts the pause request.
Completed, failed, cancelled, and stale turns are not revived by pause/resume.
New steering on a terminal/stale target raises `TurnKit::Error`; an exact retry
of an already accepted input returns its receipt even after completion.

Steering keys are nonempty strings, unique **per turn**. A retry with different
text or principal raises `ToolError`. Receipts contain `id`, `key`, `turn_id`,
per-turn `sequence`, `text`, and `principal`. They acquire `message_id` when
inserted into the transcript, then `request_id` when first included in a
reserved model request. Read refreshed receipts in
`turn.control_state(principal: ...).dig("controls", "inputs")`.
No `message_id` means queued; a `message_id` without `request_id` means inserted
but not yet requested. Inputs on a cancelled/failed turn may never be consumed.
Cascade applies to descendants present under the root lock at each invocation;
keys deduplicate per target, not across a changing tree. Order within each
turn is lock-serialized acceptance order. There is no cross-agent total order.

Delivery keys retain the existing global uniqueness contract. `post` uses the
destination itself as the source and records the sender principal in the
delivery/message. It never grants the sender's authority to the receiving
agent: automatically created turns retain the **destination conversation's**
principal. Steering likewise does not replace the target's execution principal.
Existing `say` and `send_message` remain supported with their existing behavior.

## Interruption and recovery boundaries

Pause is cooperative, not an instantaneous kill. A dispatched model request or
tool may finish, incur usage/cost, and commit its result. The executor checks
controls before model dispatch, between tool calls, before child launch, before
publishing final output, and before dependency suspension. Dispatch is reserved
under the same root lock as controls; a control arriving after that reservation
cannot recall the call. A tool's custom Ruby implementation (including nested
remote calls) is one unit of work. Compaction and output checking preserve their
completed work before the enclosing runtime observes controls.

When steering arrives during a model request, the response is recorded but its
stale tool proposals are **not executed first**. Unexecuted proposals get durable
cancelled/skipped executions and matching tool-result messages. Known completed
results remain intact; interrupted effects remain explicitly unknown. Only then
are the ordered human inputs appended and a revised model plan requested.
Every proposed tool ID has a result before the next user message is sent to the
provider. Raw assistant messages are intermediate candidates, not published
research output; publish from completed turn output, not `on_event` callbacks.

Application of input to the transcript is atomic with its receipt and phase
change. Recovery does not append it again. `request_id` identifies the **first
reserved request**, also passed in the client's `metadata[:request_id]`; it is
not proof that the provider received it. A worker dying between reservation,
network I/O, and response persistence can require another provider request.
TurnKit does not promise exactly-once provider execution or replay-safe external
writes. Pause and cancellation cannot undo writes made by tools.

Pause preserves phase, results, usage, iteration counts, and dependency edges.
Reconciliation, delivery, and child completion do not unpause a paused turn.
Timeout is elapsed wall time from original submission/start, **including pause**;
resume may fail immediately on timeout or an exhausted budget. An in-flight
failure or exhausted budget can terminate rather than acknowledge a pause.
Jobs and periodic `TurnKit.reconcile_stale!` remain necessary for missed enqueues
and dead workers. A process-death pause is acknowledged after recovery fences
the old worker and reaches the boundary.

## Subtrees and approval gates

For a research subtree, use `descendants: :cascade` for pause, steering, and
resume. A parent already joined to children keeps those waits. Steering waits
for those children to settle, retains their findings, closes remaining proposals,
and replans rather than publishing the pre-steering parent candidate. A paused
parent can have running children with `:retain`; their completion cannot unpause
it. For a full-subtree acknowledgment, inspect each affected live turn, not only
the parent. Resume the cascade to avoid leaving a parent waiting on paused
children. Cascade resume also resumes individually paused descendants; use
`:retain` on selected turns when the application needs different approval gates.

Separately created `agent.run(...)` roots/spinoffs are outside the subtree.
The existing `launch_agent` model tool, despite independent scheduling, still
creates parent-linked children and therefore participates in cascade controls,
just as it does in cancellation. Create application-owned spinoffs as new roots
when they must be independent of these controls. Existing explicit completion
callbacks remain durable next-turn messages; they are findings, not automatic
publication of final application output.

A paused turn blocks automatic wake in its conversation, including messages
and callbacks. To install an approval gate without an enqueue race:

```ruby
run = agent.run(task, principal: principal, async: true)
run.pause!(principal: principal)
run.perform_later # submitted, but still paused
# After application approval:
TurnKit.load_turn(run.id).resume!(principal: principal)
```

TurnKit does not evaluate approvals. Serialize approval decisions in application
records, and authorize resume accordingly. Use background execution for joined
subtrees; inline Ruby call stacks are not durable continuations. Standalone
`paint`/`view_media` operations are not resumable research loops; expose them as
tools of a submitted research turn when they need these controls.

## Rails/Active Job and reconnect

```ruby
# Initializer: build/register your agent in every process.
TurnKit.store = TurnKit::ActiveRecordStore.new
TurnKit.register(ResearchAgent) # a configured TurnKit::Agent instance
TurnKit.authorization_policy = ResearchAuthorization # implements authorize?
# config.active_job.queue_adapter = :sidekiq

# Controller action (authorize the application record before loading TurnKit IDs):
research = current_user.researches.find(params[:id])
principal = { "user_id" => current_user.id }
turn = TurnKit.load_turn(research.turn_uid)
turn.pause!(principal: principal, descendants: :cascade)
render json: turn.control_state(principal: principal)

# Poll/reconnect. Keep a separate cursor per conversation.
conversation = TurnKit.load_conversation(research.conversation_uid)
messages = conversation.messages_after(params.fetch(:after, 0).to_i, principal: principal)
render json: { messages: messages.map(&:to_h),
  after: messages.last&.sequence || params.fetch(:after, 0).to_i,
  control: turn.control_state(principal: principal) }

# A recurring job in the application's existing scheduler:
class ReconcileResearchJob < ApplicationJob
  def perform
    TurnKit.reconcile_stale!
  end
end
```

Authorize `:pause`, `:resume`, `:steer`, `:read_control`, and `:read_messages`;
`post` uses existing `:send_message`. Control writes authorize every selected
turn before making any changes. `read_control` receives either `turn:` for a
turn snapshot or `destination_conversation:` for a delivery receipt. Reads of
legacy low-level APIs remain trusted; do not expose them directly to clients.
`messages_after(sequence, principal: nil)` returns messages strictly after the
cursor in conversation sequence order, filtering provider/thinking parts from
the UI projection. It currently reads the conversation history before filtering;
it is not a paginated event bus. Control snapshots are separate from transcript
cursors, and should be fetched on reconnect even when there are no new messages.
Existing tool executions and turn usage/output APIs supply durable results.
`on_event` is still inline and non-durable. No hidden reasoning is added as UI
progress. Queued-input editing/withdrawal is not implemented; submit a subsequent
steering correction or cancel, rather than mutating transcript/store records.

## Compatibility and deployment

No new database migration on the 0.6.0 schema: controls and request receipts use
existing turn options, and sender identity uses delivery payload/message metadata.
Older installations still require the 0.6.0 durable-orchestration migration.
Update application status enums/check constraints for `paused`. Custom stores
must treat paused turns as conversation blockers but exclude them from actionable
and stale-inline scopes. Preserve unknown options keys when updating runtime
state. Do not run old workers alongside new interactive controls: old executors
do not observe pause requests or steering. Upgrade/drain workers together before
enabling this API. Rails 7.2 and 8.1/Active Job/PostgreSQL contract tests exercise
the runtime. The [interactive validation app](../examples/interactive_validation/README.md)
adds real Sidekiq workers and opt-in GPT-6 Astra/xhigh provider scenarios.
Application authorization, approval ownership and deployment still need validation
in the receiving application.

## GPT-6 Astra and provider continuation state

OpenAI requires Responses for GPT-6 Astra function calling. RubyLLM 1.16 uses
Chat Completions and cannot supply that endpoint. Opt into RubyLLM 2.0.0.rc2
explicitly in the application's Gemfile; it is a prerelease, not a mandatory
stable dependency upgrade. The same TurnKit adapter supports both versions:

```ruby
# Gemfile, replacing the application's ruby_llm 1.16 constraint:
gem "ruby_llm", "2.0.0.rc2"

# Agent registration:
require "ruby_llm"
RubyLLM.config.max_retries = 0 # choose retries deliberately for paid work

agent = TurnKit::Agent.new(name: "research", model: "gpt-6-astra",
  thinking: { effort: :xhigh },
  client: TurnKit::Adapters::RubyLLM.new(protocol: :responses),
  tools: research_tools)
```

The adapter reads `OPENAI_API_KEY`, sends `reasoning.effort: "xhigh"`, and does
not substitute models/efforts. The validation app checks outgoing parameters
and actual provider response metadata. RubyLLM owns HTTP, retries and protocol
encoding; TurnKit calls its public single-response `generate` and exclusively
owns tool execution. RubyLLM 1.16 retains its private `provider_completion`
compatibility path. Image/media API changes have deterministic regression
coverage, not live media-provider coverage in this campaign.

RubyLLM 2 and the native 1.16 providers include thinking in output tokens;
TurnKit converts them to exclusive output/thinking buckets to avoid double counts.
Configure current `TurnKit.cost_rates` or a cost calculator when using spend
limits without a matching RubyLLM pricing entry. Revalidate new SDK releases
before changing the pinned prerelease.

Responses are stateless (`store: false`). Original output items and encrypted
reasoning are retained as opaque provider parts for continuation, including after
process reconstruction. `messages_after` excludes these parts from UI data.
Never publish raw stored provider parts or hidden reasoning as activity.

Native Anthropic/Gemini also preserve complete ordered assistant content/parts,
including thinking, redacted blocks and per-tool signatures. RubyLLM 2 receives
`raw_content`; 1.16 receives `Content::Raw`. The 1.16 Gemini codec needs normalized
calls omitted during raw replay to avoid duplicate calls; the adapter retains
function-result names separately for that request. TurnKit still owns execution.
Only matching provider state is replayed; no signatures are fabricated or copied
between providers. Already-lost metadata in old stored messages cannot be restored.

Live native validation covers `claude-opus-4-8` and `gemini-3.1-pro-preview`, each
with `thinking: { effort: :high }`, on both SDK versions. Use the default native
adapter (`TurnKit::Adapters::RubyLLM.new`) and the corresponding API key. This is
not proof that every newer model works: Opus 5 lacks reasoning metadata in the
installed 1.16 registry. No model-ID bypass is added. See the validation app for
exact model/effort verification and non-streamed continuation/recovery evidence.

Next-turn deliveries retain their chronological UI sequence. In model input,
each delivery appears at its first receiving turn's frozen-context boundary,
after previous completed work and before that receiving turn's local messages.
This prevents a busy-time delivery from splitting an earlier tool exchange or
being overridden by steering that applied only to the earlier turn.
