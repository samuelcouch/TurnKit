# Runtime hardening

## Implementation plan and boundaries

The seven changes build on existing turns, tools and store transactions rather than a second runtime:

| Concern | Implementation | Regression coverage |
| --- | --- | --- |
| Wait cycles | Serialize graph insertion and reject reachable cycles | Opposite concurrent edges in memory and PostgreSQL |
| Context isolation | Snapshot boot contributors; scope contributors and JSON context per agent/run | Concurrent agents and mutation isolation |
| Authorization | Application-owned principal and central policy before actions | Denied delivery, revoked callbacks, no unauthorized writes |
| Cancellation | Terminal transition, claim fencing, transcript repair, optional descendant cascade | In-flight response, buffered wake, sibling preservation |
| External effects | Stable execution key and explicit replay-safety contract | Repeated crash/retry with deduplicated effect |
| Maintenance | Bounded active-row queries and fair rotation | Blocked batches and historical rows |
| Specialists/skills | Ordinary agents with scoped tools and persisted skill activation | Read-only validation, image gate/references, load-before-dispatch |

## Context and identity

`Agent.new(context_contributors: [...])` owns dynamic contributors. `Agent#run(context: {...})`
persists run context in turn options; `Agent#conversation(context: {...})` persists conversation
context. Child agents do not inherit request context unless the application includes it in their
task. Global contributors remain boot-time compatibility defaults; do not mutate them per request.
Global contributors are copied when an agent is constructed, not read afresh on every request.
Use `inherit_globals: false` for agents that must not receive those defaults. Run context is
JSON-copied on input and retrieval. Contributors and custom tools are trusted Ruby code; captured
mutable objects remain the application's responsibility, not a process-isolation boundary.
The application may pass an authenticated, JSON-serializable `principal:` to `run`; model arguments cannot set it.
Buffered-delivery continuations use the destination conversation metadata key `"principal"`; they
never inherit the sender's identity.

## Authorization

Set `TurnKit.authorization_policy` to a callable (or object implementing `authorize?`) accepting
`(action, principal:, **resources)`. It must return literal `true`; all other responses deny before
the tool, launch, message, wait, or cancellation side effect. No policy preserves trusted
single-application behavior. TurnKit does not persist pretend approvals; applications needing
approval must implement a real paused/resume workflow externally.

```ruby
TurnKit.authorization_policy = lambda do |action, principal:, **resources|
  # Your application resolves persisted identity and resource ownership here.
  AccessPolicy.allowed?(principal, action, resources)
end
run = agent.run("Research the request", principal: current_user.id,
  context: { account_id: current_account.id }, async: true).perform_later
run.cancel!(principal: current_user.id, descendants: :cascade)
```

Identity is not authentication: never accept `principal:` directly from untrusted request JSON.
Low-level store access and arbitrary developer tool code are trusted application operations.
Delivery keys are store-wide. Reusing a key is a retry only when the source, destination,
source turn and JSON payload match; otherwise it raises `ToolError` without returning the
existing message. Use application-namespaced keys for unrelated requests.
Implicit background subagent joins use the same `:wait` authorization as explicit waits;
denial rolls back the child creation and wait together.

## Waiting, cancellation, and recovery

Wait insertion is serialized as one graph transaction (a PostgreSQL transaction advisory lock)
and rejects direct or transitive cycles, including concurrent opposite edges and conversation
serialization dependencies. Each conversation is conservatively treated as one serial lane:
unfinished peers' waits count even when the requested turn has no explicit wait of its own.
This may reject a conversation-level cycle that a particular execution ordering could resolve;
use independent conversations rather than depending on that ordering. `Run#cancel!` and
`Turn#cancel!` revoke the claim; choose `descendants: :retain` (default) or `:cascade`. Callbacks and
waiters observe cancellation as terminal, interrupted tools receive transcript results, and a
buffered inbox is woken after cancellation commits. Callback policy revocation is recorded in the
terminal turn's `options["callback_denied"]` without undoing its terminal state. A remote provider
call already sent is not aborted, but
its stale worker cannot commit through the fenced execution store.

Every `ToolContext` has stable `idempotency_key`. Tools default to `recovery :unknown`: interrupted
effects are reported as outcome unknown and are not replayed. A tool may declare `recovery
:replay_safe` only when its integration uses that key; stale background work then retries it. This
is not a universal exactly-once guarantee.

```ruby
class PublishReport < TurnKit::Tool
  recovery :replay_safe
  parameter :body, :string, required: true

  def call(body:, context:)
    ReportsAPI.publish(body, idempotency_key: context.idempotency_key)
  end
end
```

Only use that declaration when the external service durably deduplicates the key (or the
effect and result share one local transaction). A new execution has a new key: business-level
deduplication across independent requests still belongs to the integration. Cancellation does
not roll back a remote effect or forcibly terminate Ruby tool code already executing.

Maintenance reads only active submitted turns and pending deliveries, in bounded oldest-updated
batches (`TurnKit.maintenance_batch_size`, default 100), touching inspected blocked work so later
rows are eventually considered. `list_submitted_turns` remains an unbounded historical listing;
stores expose `list_actionable_turns(limit:)` for maintenance. Atomic wait-graph mutation requires
PostgreSQL for `ActiveRecordStore`; unsupported adapters fail explicitly.
The public `reconcile_stale!` path also uses a bounded `list_stale_inline_turns(before:, limit:)`
query for abandoned inline work; repeat calls drain additional batches rather than loading
all historical turns. Custom stores must implement that query as well.

New install and durable upgrade migrations include the maintenance/pending-delivery indexes.
Applications that already installed the earlier durable schema should add these in a new migration:

```ruby
add_index :turnkit_turns, [:status, :submitted_at, :updated_at], name: "index_turnkit_turns_on_maintenance"
add_index :turnkit_deliveries, [:delivered_at, :created_at], name: "index_turnkit_deliveries_on_pending"
```

Custom stores must implement the new coordination contracts in `Store`, including atomic graph
transactions and actionable queries. Historical transcript retention is still application policy;
bounded maintenance is not automatic archival. See [specialists and skills](specialists.md).
