# TurnKit Architecture Plan: Skills-First Workflows, Contract Loops, Durable Messages

Status: proposed
Date: 2026-06-10
Compatibility: **intentionally breaking.** TurnKit is a new gem with one user. No aliases, no deprecation shims, no legacy names. Every rename is a hard cut.

## Thesis

Developers should not be prompting agents. They should design loops that prompt their agents: define an expected input and output, prompt the orchestrator, and let the loop enforce the contract.

Three principles drive every change in this plan:

1. **Skills are the single source of truth for plain-English rules.** One Markdown file drafts the output, audits the output, and drives the revision loop. SKILLS.md-style progressive disclosure (metadata listed, content loaded on demand, rehydratable by key) is implemented for real, not advertised and missing.
2. **Bad output re-enters the loop instead of ending the run.** Deterministic validators, LLM judges, and terminal-tool checks all feed the same behavior: "Edit this. Apply the skill. Do not deviate." Bounded by budget.
3. **The message transcript is the durable spine and must never lie.** Every advertised tool call gets a result. Provider content (thinking blocks, reasoning items) round-trips. Derived data is derived, not stored twice.

## Current defects this plan fixes

Found in the architecture audit (all verified against the code; the orphan bug reproduced empirically):

| # | Defect | Severity |
|---|--------|----------|
| D1 | Terminal tool orphans sibling tool calls → transcript permanently rejected by providers on follow-up turns (`tool_runner.rb#dispatch`) | High |
| D2 | Thinking/provider content dropped: `Result` and `Message` have no slot for Anthropic thinking blocks or OpenAI reasoning items → `thinking:` + tools is structurally unsound | High |
| D3 | `available_skills` prompt says "load a skill" but no `load_skill` tool exists | High |
| D4 | Output policy failures dead-end (`:report` ships dirty output, `:fail` kills the run); no revision loop | High |
| D5 | `Message#content` is a persisted second source of truth that nothing reads | Medium |
| D6 | Heartbeat only beats on model calls; long tool executions get reaped by `reconcile_stale!` | Medium |
| D7 | No compare-and-swap on `pending → running`; two workers can run the same turn | Medium |
| D8 | Budget state is memory-only; restarts reset limits; `root_started_at` anchored at turn build, not run start | Medium |
| D9 | Sub-agent failures return `{"status" => "failed", "result" => ""}` with no error detail | Medium |
| D10 | `Workflow` mirrors 27 Agent params across three places; drift already present | Medium |
| D11 | Workflow `instructions:` replaces (not composes) the orchestrator preamble | Medium |
| D12 | Dual naming: `cost_limit`/`max_spend`, `output_audit`/`output_policy` threaded through every layer | Low |
| D13 | `Run#messages` does pointless `load_conversation` round trips, returns raw hashes (inconsistent with `Conversation#messages`) | Low |
| D14 | Unknown tools / invalid arguments consume `max_tool_executions` budget | Low |
| D15 | `payload.to_json` computed twice per tool result | Low |

## Explicit non-goals

- **No graph/pipeline DSL.** The single-conversation model-tool loop plus skills that describe procedure in English is the product. Fabro-style DOT graphs are a different product.
- **No `guidelines:` concept.** Rejected in design review. A guideline is a Skill; enforcement is `output_policy:` accepting a Skill.
- **No tool-ordering enforcement engine** (`require_tools:` etc.). Ordering rules live in terminal-tool validators where they are testable Ruby (the `read_urls` pattern in amazon_memo_writer).
- **No skill folders/frontmatter/versioning yet.** Single-file skills with key/name/description/content. Folders become worthwhile only with large resource bundles; revisit when an example needs it.
- **No buzzword/style rule engine.** Deterministic checks are plain Ruby in developer tools; subjective checks are plain English in skills.

---

## Phase 0: Naming and surface cleanup (breaking)

Goal: one name per concept before building on top. Pure deletion/rename, no behavior change.

### 0.1 `max_spend` everywhere; `cost_limit` deleted

- `TurnKit.cost_limit` accessor → `TurnKit.max_spend` (real accessor, delete the alias methods at `turnkit.rb:100-106`).
- `Agent#initialize(cost_limit:)` → `max_spend:`. `Budget#initialize(cost_limit:)` → `max_spend:`. `Budget#cost_limit` reader → `max_spend`.
- `Workflow`: delete the `cost_limit` keyword and `max_spend` alias method; single `max_spend:` keyword, no `||` merging logic in `run`.
- README: delete the "`TurnKit.cost_limit` remains supported" paragraph.

### 0.2 `output_policy` everywhere; `output_audit` config deleted

- `Agent`/`Workflow` keywords: `output_policy:`, `output_policy_mode:`, `output_policy_model:`, `output_policy_thinking:` only. Delete `output_audit:`, `output_audit_mode:` keywords and `normalize_output_policy_options`'s both-given guard (nothing to guard).
- The **result** of auditing keeps the class name `OutputAudit` (it is an audit result), but the public accessor on Run/Turn renames: `run.output_audit` → `run.policy_audit`, `run.output_audit_clean?` → `run.policy_clean?`. Persisted under turn `options["policy_audit"]`.
- `TurnKit.audit_output` → `TurnKit.check_output_policy` (or delete from public surface; it is only used internally by `Turn` — prefer delete, keep `OutputAudit.check`).

### 0.3 Workflow collapses to an options-forwarding facade

Replace the 27-attr mirroring (`workflow.rb` init + `build_agent` + attr_readers) with one frozen hash:

```ruby
class Workflow
  ORCHESTRATOR_PREAMBLE = <<~TEXT.strip
    You are an autonomous task orchestrator... (current DEFAULT_INSTRUCTIONS)
  TEXT

  attr_reader :name, :options

  def initialize(name:, instructions: nil, **options)
    @name = name.to_s
    raise ArgumentError, "name is required" if @name.empty?
    @options = options.merge(
      name: @name,
      prompt_mode: options.fetch(:prompt_mode, :task),
      instructions: compose_instructions(instructions)
    ).freeze
    @agent = Agent.new(**@options)
  end

  def run(prompt = nil, task: nil, input: nil, async: false, subject: nil, metadata: {}, **overrides)
    agent(**overrides).run(task || prompt, input:, async:, subject:, metadata:)
  end

  def agent(**overrides)
    overrides.empty? ? @agent : Agent.new(**@options.merge(overrides.compact))
  end

  private
    def compose_instructions(instructions)
      [ORCHESTRATOR_PREAMBLE, instructions.to_s.strip].reject(&:empty?).join("\n\n")
    end
end
```

- Fixes D10 (one place to thread a new Agent option: nowhere) and D11 (developer instructions **compose with** the orchestrator preamble; passing `instructions:` no longer silently deletes the loop framing). To opt out of the preamble entirely: `Workflow.new(preamble: false, ...)` — a single explicit escape hatch.
- Delete per-option attr_readers. Anything needed is `workflow.options[:max_spend]` or on the agent.
- Validation of unknown options falls through to `Agent.new` keyword errors, which is exact and free.

### 0.4 `Run#messages` cleanup

- Delete the `load_conversation` round trip; group `turn_records` by `conversation_id`, list each conversation once, return `Message` objects:

```ruby
def messages
  turn_records.map { |r| r.fetch("conversation_id") }.uniq.flat_map do |cid|
    turn.store.list_messages(cid).map { |attrs| Message.new(attrs) }
  end
end
```

Fixes D13 and the latent duplicate-messages case.

### Verification

- `bundle exec rake test` with all call sites mechanically renamed.
- `rg -n "cost_limit|output_audit_mode|output_audit:" lib test examples` returns only `OutputAudit` class internals.

---

## Phase 1: Message architecture — content parts are canonical (breaking schema)

Goal: fix D2 and D5 with one move. `Message#content` becomes the single source of truth as an ordered array of typed parts; `text` becomes derived.

### 1.1 Part vocabulary

```ruby
# content is an ordered array of part hashes:
{ "type" => "text",        "text" => "..." }
{ "type" => "thinking",    "text" => "...", "signature" => "...", "redacted" => false }
{ "type" => "tool_call",   "id" => "c1", "name" => "lookup", "arguments" => {...} }
{ "type" => "tool_result", "tool_call_id" => "c1", "text" => "...", "error" => false }
{ "type" => "provider",    "kind" => "openai_reasoning", "data" => {...} }  # opaque round-trip
```

Mirrors Fabro's `ContentPart` (text / thinking with signature / tool call / tool result / opaque `Other`). `provider` parts are never interpreted by TurnKit; they exist so adapters can replay provider-required items verbatim.

### 1.2 `Message` changes

- `content` is required and canonical. `text` is **derived**: `def text = content of type text/thinking-excluded joined` — a method, not a constructor attribute, not persisted independently.
- Constructor still accepts `text:` as sugar that builds a one-part content array. `to_h` emits `content` only (delete `"text"` from the persisted hash).
- `metadata["tool_calls"]` (current home of tool call data on assistant messages) **moves into content parts**. `metadata["tool_call_id"]` on tool results moves into the part. Metadata returns to being actual metadata.
- KINDS stay (`text | tool_call | tool_result | context_summary`) as a coarse index; kind is derivable from parts but kept as a stored column for query ergonomics (`kind = "tool_result"` filtering in stores). This is the one deliberate derived-but-stored field; document it as such.

### 1.3 `Result` changes (adapter contract)

- `Result.new(text:, tool_calls:, ...)` gains `parts:` — the full ordered provider content. When `parts` is given, `text`/`tool_calls` are derived from it; adapters that can't supply parts keep working with the simple form (a text part is synthesized).
- `Adapters::RubyLLM#normalize_response` extracts thinking blocks and provider items into `parts` where RubyLLM exposes them; raw passthrough into `provider` parts otherwise.

### 1.4 `MessageProjection` rebuilds from parts

- Assistant messages project parts in order, **provider/thinking parts first**, then text, then tool calls (the order Anthropic and OpenAI require).
- `Adapters::RubyLLM#add_message` learns to attach thinking/provider parts to replayed messages. If RubyLLM's message model cannot carry a given provider part, the adapter drops it **and strips the matching policy**: never send a transcript that half-satisfies a provider constraint. Document the limitation per provider.
- Compaction's `sanitize_message` and token estimation read derived `text` — unchanged behavior.

### 1.5 Persistence

- `MemoryStore`: no change (stores the hash).
- `ActiveRecordStore` + generator templates: drop the `text` column from `turnkit_messages`; `content` (json) is canonical. Regenerate the install migration template — no migration path needed (new gem).

### Verification

- New tests: round-trip a thinking part through Message → store → projection; assert thinking precedes tool_call parts in projected assistant messages.
- Manual: run `examples/workflow_researcher` with an Anthropic model and `thinking: { budget: 4_000 }` + tools; previously structurally broken, must complete.

---

## Phase 2: Tool-loop correctness (D1, D6, D9, D14, D15)

### 2.1 Terminal tool never orphans siblings (D1 — highest priority fix in the plan)

In `ToolRunner#dispatch`, when an execution completes and `ends_turn?`, append synthetic results for every not-yet-dispatched call before returning:

```ruby
def dispatch(tool_calls)
  tool_calls.each_with_index do |tool_call, index|
    execution = run(tool_call)
    next unless execution.completed? && tool_for(tool_call.name)&.ends_turn?

    skip_remaining(tool_calls.drop(index + 1), terminal: tool_call)
    return execution
  end
  nil
end

def skip_remaining(calls, terminal:)
  calls.each do |call|
    payload = { "skipped" => true, "message" => "not executed: turn ended by #{terminal.name}" }
    execution = ToolExecution.new(create_execution(call))
    turn.store.update_tool_execution(execution.id, "status" => "cancelled", "result" => payload, "completed_at" => Clock.now)
    append_result(execution, call, payload)
    turn.emit("tool_call.skipped", id: call.id, name: call.name)
  end
end
```

Invariant (Fabro's rule, adopted): **every tool call id advertised in an assistant message gets exactly one tool_result message, on every path** — success, error, budget denial, unknown tool, terminal skip. Add a test asserting the invariant across all five paths.

### 2.2 Heartbeat from the tool runner (D6)

`ToolRunner#run` touches `heartbeat_at` before and after each execution (`turn.store.update_turn(turn.id, heartbeat_at: Clock.now)` — wrap in a small `turn.heartbeat!`). Long sub-agent and web tools no longer get reaped mid-flight by `reconcile_stale!`.

### 2.3 Sub-agent errors propagate (D9)

`SubAgentTool#call` payload gains the child's error:

```ruby
{
  "conversation_id" => ..., "turn_id" => ..., "status" => child.status,
  "result" => child.output_text, "output_data" => child.output_data,
  "error" => (child.store.load_turn(child.id)["error"] if child.failed?)
}.compact
```

The orchestrator can now decide retry / rephrase / route on worker failure — required for "manage your agent fleet".

### 2.4 Budget counts real work only (D14)

Move `count_tool_execution!` after the unknown-tool and `arguments_error` checks in `ToolRunner#run`. Validation failures still produce error tool_results (invariant 2.1) but don't consume `max_tool_executions`.

### 2.5 Serialize once (D15)

`finish_success`/`finish_error` compute `payload.to_json` once and pass it to both `append_result` and the event payload.

### Verification

- Re-run the audit reproduction scenarios (terminal-first-of-two, budget-denial-mid-batch) as permanent tests; assert zero orphaned ids and follow-up-turn projectability.

---

## Phase 3: Skills as intended (D3)

### 3.1 `LoadSkill` tool

New `lib/turnkit/load_skill_tool.rb`:

```ruby
class LoadSkillTool < Tool
  tool_name "load_skill"
  description "Load the full instructions for an available skill by key."
  parameter :key, :string, required: true, description: "Skill key from <skills_available>."

  def self.for(skills)
    Class.new(self) do
      @skills = skills.to_h { |skill| [skill.key, skill] }
      class << self; attr_reader :skills; end
    end
  end

  def call(key:, context:)
    skill = self.class.skills[key]
    raise ToolError, "unknown skill: #{key}. Available: #{self.class.skills.keys.join(", ")}" unless skill

    { "key" => skill.key, "name" => skill.name, "content" => skill.content }
  end
end
```

- `Agent#effective_tools` appends `LoadSkillTool.for(effective_available_skills)` whenever available skills exist. Tool-name collision with a developer tool named `load_skill` raises at construction (existing duplicate check covers it).
- `available_skills_section` prompt text updated: "These skills are listed but not loaded. When a task matches a skill description, call load_skill with the skill key before relying on it."

### 3.2 Rehydration semantics (document, don't build)

- Loaded skills (`skills:`) live in the system prompt, which is re-rendered every model call — they survive compaction by construction.
- `load_skill` results are tool_result messages; compaction may summarize them away. The model re-loads by key when needed; the catalog (`<skills_available>`) is always visible. No new machinery: rehydration = call the tool again. Add one line to the compaction summary template's "Tool Results To Remember" guidance: record which skills were loaded.

### 3.3 Skill descriptions become load-bearing

- `Skill.from_file` parses an optional minimal YAML frontmatter block (`name:`, `description:`) — 10 lines, no YAML dependency beyond stdlib `yaml`. Descriptions matter once progressive disclosure is real; files should self-describe. Body without frontmatter keeps working.

### Verification

- Test: agent with `available_skills` + scripted client that calls `load_skill` → content returned, unknown key → ToolError listing keys.
- Test: `effective_tools` includes `load_skill` iff available skills exist.

---

## Phase 4: The contract loop (D4) — the centerpiece

Goal: `define expected input and output → prompt orchestrator → loop enforces`. One file of plain-English rules drafts, audits, and revises.

### 4.1 `OutputPolicy.from_skill` + Skill acceptance

```ruby
# output_policy.rb
def self.from_skill(skill, **options)
  new(name: skill.key, content: skill.content, **options)
end
```

`Agent#normalize_output_policy` gains:

```ruby
when TurnKit::Skill
  OutputPolicy.from_skill(value, model: model || TurnKit.output_policy_model,
                                 thinking: thinking || TurnKit.output_policy_thinking)
```

The auditor instructions in `OutputPolicy` add one sentence: "The policy may be a skill; treat its output-facing rules as normative and ignore process steps that are not observable in the output."

### 4.2 `output_retries:` revision loop

New keyword on `Agent`/`Workflow` (default `0` = current gate behavior). Restructure `Turn#run!` so auditing happens **inside** the loop and a dirty audit re-enters it:

```
loop:
  budget.check! / count_iteration! / maybe_compact!
  result = call model
  if tool_calls:
    terminal = dispatch tools
    candidate = terminal ? completion_message : nil
  else:
    candidate = result.text
  next unless candidate                      # keep looping on non-terminal tool turns

  audit = check_output_policy(candidate)
  if audit.clean? || revisions_used >= output_retries:
    complete(candidate, audit)               # then :report/:fail semantics apply
    break
  revisions_used += 1
  append_revision_message(audit)             # re-enters loop
```

`append_revision_message` builds a user message that **rehydrates the skill content** (not just the key — by revision time the original injection may be compacted):

```text
The previous output failed policy checks.

Revise the previous output. Do not introduce new claims.
Do not deviate from the skill below.

<skill key="memo_voice">
{skill.content}
</skill>

Violations:
1. {rule}: {message}
...

{If the turn ended via a terminal tool: "Resubmit via {tool_name}."}
```

Notes:

- Skill-backed policies contribute their content to the revision message; lambda policies contribute violations only. Multiple skill policies each get a `<skill>` block.
- Revision iterations consume `max_iterations` and `max_spend` like any other iteration — the existing budget is the circuit breaker; no separate revision budget.
- After retries exhaust: existing `output_policy_mode` semantics (`:report` completes with `policy_audit` metadata attached; `:fail` fails the turn). Default mode flips to `:fail` — with a revision loop in front of it, failing loudly is the right default for a contract-driven workflow.
- Emit events: `output_policy.revision` (violation count, attempt), keeping the deep-monitoring story coherent.
- Terminal-tool deterministic validation (ToolError → model retries) is untouched; it remains the cheap inner loop. The policy loop is the outer loop for whole-output judgment.

### 4.3 `input_schema:` — the input half of the contract

Minimal, deterministic, free (no model call). New keyword on `Agent#run`/`Workflow`:

```ruby
workflow = TurnKit::Workflow.new(
  name: "memo_writer",
  input_schema: {
    "type" => "object",
    "properties" => { "project_id" => { "type" => "string" } },
    "required" => ["project_id"]
  },
  ...
)
workflow.run("Write a memo about Project ABC123", input: { project_id: "ABC123" })
```

- Validation reuses `Tool`'s existing type-check logic extracted into a small shared `SchemaCheck` module (type + required + enum; not full JSON Schema — deliberately). Raises `InputError` before any conversation/turn is created. ~40 lines including extraction.
- This is the only place input is validated; no input audit loop (inputs are the application's responsibility; fail fast).

### 4.4 Canonical example shape (what Phase 6 refactors toward)

```ruby
voice = TurnKit::Skill.from_file("skills/memo_voice.md")        # NEVER em dashes, NEVER buzzwords, ...
procedure = TurnKit::Skill.from_file("skills/memo_workflow.md") # research -> draft -> edit -> submit

workflow = TurnKit::Workflow.new(
  name: "memo_writer",
  tools: [GetProjectDetails, WebSearch, ReadWebPage, SubmitMemo],
  skills: [procedure, voice],
  output_policy: [voice, ->(output) { Memo.rendered_violations(output) }],
  output_retries: 2,
  output_policy_mode: :fail,
  input_schema: { "type" => "object", "required" => ["project_id"],
                  "properties" => { "project_id" => { "type" => "string" } } },
  max_iterations: 12, max_spend: 1.00,
  max_tool_executions_by_name: { "web_search" => 2, "read_web_page" => 6 }
)
```

One voice file, used twice. No rule stated more than once.

### Verification

- Scripted-client tests: dirty-then-clean audit (1 revision, completes), dirty × 3 with `output_retries: 2` (`:fail` → failed with `policy_audit`; `:report` → completed dirty), terminal-tool output revised and resubmitted via the terminal tool, revision message contains skill content + violations.
- Budget test: revision loop respects `max_iterations`.

---

## Phase 5: Durability (D7, D8)

### 5.1 Compare-and-swap turn claim (D7)

Store contract gains a conditional update:

```ruby
# Store
def claim_turn(id, from: "pending", to: "running", **attrs)  # → turn hash or nil
```

- `MemoryStore`: check-and-set under the existing mutex.
- `ActiveRecordStore`: `turn_class.where(uid: id, status: from).update_all(...)` then reload; `nil` when 0 rows.
- `Turn#run!` starts with `claim_turn` and returns `self` (no-op) when the claim fails. Two workers can no longer double-run a turn.

### 5.2 Budget derived from the store, not duplicated in memory (D8)

Single-source-of-truth fix: budget *consumption* is already in the store (turn records carry cost/usage; tool executions carry counts). On `Turn#run!`/resume:

```ruby
Budget.resume(store:, root_turn_id:, limits:) # seeds @cost, @tool_executions(_by_name),
                                              # @iterations from persisted records
```

- `@iterations` seeds from a persisted per-turn `options["iterations"]` counter incremented in `add_usage!` (one extra key in an existing update — not a new write).
- `root_started_at` anchors to the **root turn's persisted `started_at`** (set on first claim), not budget-object construction. Async runs no longer burn timeout while queued.
- In-memory counting during a run is unchanged (cheap, correct within a process); the store seed makes restarts and multi-process resumes honest.

### Verification

- Test: two threads race `run!` on one pending turn against MemoryStore; exactly one executes.
- Test: kill/rebuild a Budget mid-run from store records; limits keep counting from where they were.

---

## Phase 6: Examples, docs, release

1. **Refactor `examples/amazon_memo_writer`**: extract `memo_voice` skill file; `output_policy: [voice, format_lambda]`, `output_retries: 2`; delete `semantic_policy`'s duplicated rule prose (fixture-URL caveats stay); keep deterministic validators in the submit tool as backstops. The `accuracy` benchmark must hold or improve — this is the acceptance test for the whole plan.
2. **Refactor `examples/workflow_researcher`**: instructions now compose with the orchestrator preamble (delete the duplicated framing).
3. **README**: rewrite Workflows section around the contract loop (skills → policy → retries → budgets); document `skills:` vs `available_skills:` semantics honestly (always-loaded vs `load_skill`); document the tool-result invariant.
4. **UPGRADE.md**: replace with a single "0.x is a clean break" section listing renames (`cost_limit`→`max_spend`, `output_audit*`→`output_policy*`/`policy_audit`, message `text` column dropped).
5. Version bump to the next minor (pre-1.0 breaking is fine); CHANGELOG entries per phase.

---

## Sequencing and dependency graph

```diagram
Phase 0 (renames, Workflow collapse)
   │
   ├─▶ Phase 1 (message parts)──╮
   │                            ├─▶ Phase 4 (contract loop) ──▶ Phase 6 (examples/docs)
   ├─▶ Phase 2 (tool loop) ─────╯         ▲
   │                                      │
   ├─▶ Phase 3 (load_skill) ──────────────╯
   │
   ╰─▶ Phase 5 (durability)   [independent; any time after 0]
```

- Phases 2 and 3 are independent of 1 and of each other; parallelizable.
- Phase 4 depends on 0 (naming), 2 (terminal-tool correctness — the revision loop continues conversations that must not be transcript-poisoned), and 3 (skill rehydration in revision messages).
- Each phase lands green (`bundle exec rake test` + the two runnable API-key-free examples) before the next starts.

## Test strategy summary

- Keep the existing 96-test suite as the regression floor; rename mechanically in Phase 0.
- Every defect D1–D15 gets a named regression test (the audit's reproduction scripts become tests in Phase 2).
- The amazon_memo_writer `accuracy` benchmark is the end-to-end acceptance gate (run manually with a real key before release; scripted-client variant runs in CI/local suite).
- New invariant tests:
  - every advertised tool_call id has exactly one tool_result (all five dispatch paths);
  - projected assistant messages order parts thinking → text → tool_calls;
  - a conversation remains projectable (no orphan ids) after any completed turn, including terminal-tool turns.

## Risks

| Risk | Mitigation |
|------|------------|
| RubyLLM may not expose thinking blocks/raw provider parts | Phase 1.3 keeps `parts:` optional; adapter degrades to text+tool_calls and strips unsatisfiable policies; document per-provider support |
| Revision loop ping-pongs (judge never satisfied) | Bounded by `output_retries` (default 0, recommended 1–2) and global budgets; revision prompt says "edit the previous output; do not introduce new claims" |
| LLM judge false-positives on process rules in skills | Auditor instruction to ignore non-observable process steps; guidance: separate procedure skill from voice skill |
| Workflow options-hash forwarding loses discoverability vs. explicit keywords | `Agent.new` keyword errors surface typos exactly; README documents the full option table in one place |
| `claim_turn` semantics differ subtly across stores | Shared store contract test module run against both MemoryStore and ActiveRecordStore (sqlite in test) |
