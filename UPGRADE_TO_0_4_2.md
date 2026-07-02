# Upgrade to TurnKit 0.4.2

This guide is for upgrading existing TurnKit apps to `0.4.2` from older
pre-1.0 versions.

## Audit summary

The current branch is not a patch-only dependency bump. It removes several
short-lived public APIs and consolidates the task-runner surface around
`TurnKit::Agent`. Treat `0.4.2` as a breaking pre-1.0 upgrade unless the removed
compatibility shims are restored before release.

If you only use plain `Conversation` turns with the built-in memory store and no
custom tools, clients, prompt contributors, workflows, or Rails store overrides,
the upgrade is usually small. Apps using workflow/orchestrator APIs should follow
the checklist below.

## 1. Update your Gemfile

```ruby
gem "turnkit", "0.4.2"
```

If you use TurnKit's default RubyLLM adapter, add RubyLLM explicitly. TurnKit no
longer depends on it at runtime.

```ruby
gem "ruby_llm", "~> 1.16"
```

Codex adapter users and apps with a custom `TurnKit::Client` do not need
`ruby_llm` unless they also use `TurnKit::Adapters::RubyLLM`.

Then update your bundle:

```sh
bundle update turnkit
bundle update ruby_llm # only if you added or already use ruby_llm
```

## 2. Replace workflows with orchestrator agents

`TurnKit::Workflow` was removed. Use `TurnKit::Agent` with
`orchestrator: true` instead.

Before:

```ruby
workflow = TurnKit::Workflow.new(
  name: "brief_writer",
  instructions: "Create source-grounded briefs.",
  skills: [source_grounded_brief],
  tools: [WebSearch, ReadWebPage],
  max_spend: 0.25
)

run = workflow.run(
  "Create a brief.",
  input: { topic: topic }
)
```

After:

```ruby
agent = TurnKit::Agent.new(
  name: "brief_writer",
  orchestrator: true,
  instructions: "Create source-grounded briefs.",
  skills: [source_grounded_brief],
  tools: [WebSearch, ReadWebPage],
  max_spend: 0.25
)

run = agent.run(
  "Create a brief.",
  input: { topic: topic }
)
```

Notes:

- `orchestrator: true` prepends the same autonomous-task preamble that workflows
  used and defaults the agent prompt mode to `:task`.
- `workflow.agent(**overrides)` no longer exists. Construct another
  `TurnKit::Agent` with the desired options.
- Per-run workflow overrides such as `workflow.run(..., max_spend: 0.10)` no
  longer have a direct equivalent. Configure those limits on the agent; agents
  are cheap to construct.

## 3. Update `Agent#run` call sites

`Agent#run` now requires the task as the first positional argument.

```ruby
# Before
agent.run(task: "Classify this lead.", input: lead)

# After
agent.run("Classify this lead.", input: lead)
```

`input:`, `async:`, `subject:`, `metadata:`, and other run options remain keyword
arguments.

## 4. Rename global model configuration

The temporary `TurnKit.model` aliases were removed.

```ruby
# Before
TurnKit.model = "gpt-4.1-mini"
model = TurnKit.model

# After
TurnKit.default_model = "gpt-4.1-mini"
model = TurnKit.default_model
```

In `TurnKit.configure`, use `config.default_model = ...`.

## 5. Rename run accessors

Update code that reads completed run results or tool activity:

| Before | After |
| --- | --- |
| `run.output` | `run.output_text` |
| `run.tool_calls` | `run.tool_executions` |
| `run.steps` | `run.turn_records.length` if you need the count |
| `run.persisted?` | remove; runs are persisted wrappers around turns |

`run.output_data`, `run.usage`, `run.cost`, `run.policy_audit`, and
`run.policy_clean?` remain available.

## 6. Update custom tools

TurnKit now passes framework context only as `context:`. The older
`turnkit_context:` keyword was removed.

```ruby
# Before
def call(title:, body:, turnkit_context:)
  turn = turnkit_context.turn
  { id: SaveReport.call(title:, body:, turn:) }
end

# After
def call(title:, body:, context:)
  turn = context.turn
  { id: SaveReport.call(title:, body:, turn:) }
end
```

`context` is now a reserved tool parameter name. Do not expose a model-visible
tool parameter named `context`:

```ruby
# Do not do this in 0.4.2
parameter :context, :string
```

If a tool class needs constructor arguments, register an instance instead of the
class:

```ruby
agent = TurnKit::Agent.new(
  name: "researcher",
  tools: [WebSearch.new(client: SearchClient.new)]
)
```

## 7. Update sub-agent calls

`TurnKit::SubAgentTool` exposes a single model-visible `task` parameter. If your
sub-agent usage previously separated `task` and `context`, include the necessary
context in the task text itself.

Before:

```json
{ "task": "Draft headlines", "context": "Product: PhotoDay" }
```

After:

```json
{ "task": "Draft headlines for Product: PhotoDay." }
```

## 8. Replace prompt contributor APIs

These prompt extension APIs were removed:

- `TurnKit.system_prompt_contributors`
- `TurnKit.model_prompt_contributors`
- `TurnKit::PromptContribution`
- prompt section override objects
- `TurnKit::SystemPrompt::CACHE_BOUNDARY`
- `TurnKit::SystemPrompt.split_cache_boundary`

Use per-agent `system_prompt:` instead. A string replaces the generated prompt.
A callable receives a `TurnKit::SystemPrompt` object.

```ruby
agent = TurnKit::Agent.new(
  name: "reporter",
  system_prompt: ->(prompt) {
    [
      prompt.stable,
      prompt.section(:tools),
      prompt.dynamic
    ].reject(&:empty?).join("\n\n")
  }
)
```

Available generated-prompt APIs:

- `prompt.to_s`
- `prompt.stable`
- `prompt.dynamic`
- `prompt.section(:tools)` and other section names

`TurnKit.prompt_sections`, per-agent `prompt_sections:`,
`TurnKit.prompt_behavior`, and `TurnKit.context_contributors` remain available.

## 9. Update custom clients and adapters

TurnKit no longer sniffs custom client method signatures before calling them.
Custom clients should subclass `TurnKit::Client` or accept the full keyword
contracts.

At minimum, update `chat` to accept `dynamic_instructions:`:

```ruby
def chat(model:, messages:, tools:, instructions:, dynamic_instructions: nil,
  temperature: nil, thinking: nil, output_schema: nil, metadata: nil,
  on_event: nil)
  full_prompt = [instructions, dynamic_instructions].compact.join("\n\n")
  # call provider...
end
```

If your client supports image generation or media analysis, also accept the full
`paint` and `view_media` keyword sets from `TurnKit::Client`, including
`metadata:` and `on_event:`.

Prompt caching changed from an embedded cache-boundary marker to explicit stable
and dynamic instructions. Adapters that support provider prompt caching should
cache `instructions` and append `dynamic_instructions` per turn.

## 10. Update custom stores

Built-in `TurnKit::MemoryStore` and `TurnKit::ActiveRecordStore` already support
the new claiming behavior.

If you maintain a custom store, implement `claim_turn` as an atomic
compare-and-set from `from` to `to`. It must return the claimed turn record when
the claim succeeds and `nil` when another worker already claimed or completed
the turn.

```ruby
def claim_turn(id, from: "pending", to: "running", **attributes)
  # Atomically update only when uid/id and status both match.
  # Return nil if no row was updated.
end
```

The old default implementation was intentionally removed because it was not safe
for concurrent workers.

## 11. Update Rails store configuration

The generated table and model names remain compatible, but custom Active Record
class configuration moved from global TurnKit attributes to the store
constructor.

Before:

```ruby
TurnKit.store = TurnKit::ActiveRecordStore.new
TurnKit.conversation_record_class = "My::Conversation"
TurnKit.turn_record_class = "My::Turn"
TurnKit.message_record_class = "My::Message"
TurnKit.tool_execution_record_class = "My::ToolExecution"
```

After:

```ruby
TurnKit.store = TurnKit::ActiveRecordStore.new(
  conversation_class: "My::Conversation",
  turn_class: "My::Turn",
  message_class: "My::Message",
  tool_execution_class: "My::ToolExecution"
)
```

Apps that used `require "turnkit"` can keep doing that. If you directly required
the old internal Active Record store path, update it:

```ruby
# Before
require "turnkit/stores/active_record_store"

# After
require "turnkit/active_record_store"
```

If you manually required `turnkit/rails/railtie`, remove that require. The Rails
install generator now lives at the conventional `lib/generators` path and should
still be available as:

```sh
bin/rails generate turnkit:install
```

## 12. Check database migrations for older Rails installs

New installs already include all current columns.

Existing Rails installs from before structured/image/media output persistence
should add `output_data` to turns if they do not already have it:

```ruby
class AddOutputDataToTurnkitTurns < ActiveRecord::Migration[7.1]
  def change
    add_column :turnkit_turns, :output_data, :json
  end
end
```

If you customized the table prefix when installing TurnKit, use your actual turns
table name instead of `turnkit_turns`.

Upgrades from the `0.2.x` series also need the `0.3.0` message-schema migration:
message content is stored as ordered typed parts in `turnkit_messages.content`,
with text derived from content. For greenfield or disposable development data,
the simplest route is usually to regenerate the current install migration and
recreate the TurnKit tables.

## 13. Update custom cost rates

`TurnKit.cost_rates` now accepts only these component keys, expressed as USD per
million tokens:

- `input`
- `output`
- `cache_read`
- `cache_write`
- `thinking`

Before:

```ruby
TurnKit.cost_rates["gpt-5"] = {
  input: 1.25,
  output: 10.0,
  cached_input: 0.125,
  reasoning: 10.0
}
```

After:

```ruby
TurnKit.cost_rates["gpt-5"] = {
  input: 1.25,
  output: 10.0,
  cache_read: 0.125,
  thinking: 10.0
}
```

Old aliases such as `cached_input`, `cache_creation`, `reasoning`, and
`*_per_million` now raise `TurnKit::ConfigError`.

## 14. Update media analysis checks

`MediaAnalysisResult#structured?` was removed. Use `data?` instead.

```ruby
# Before
analysis.structured?

# After
analysis.data?
```

## 15. Non-breaking changes to know about

- Turn runtime state such as iteration counts and output-policy audits now lives
  under `options["state"]`. Reads fall back to the older top-level keys, so no
  data migration is required for this change.
- Compaction examples now use symbol keys, but string keys are still accepted.
- Built-in memory and Active Record stores already implement atomic turn claims.
- Generated Rails model/table names still work. Only custom class configuration
  moved to `ActiveRecordStore.new(...)`.
- Removing the transitive `ruby_llm` dependency does not affect Codex adapter or
  custom-client users.

## 16. Suggested upgrade order

1. Create a branch and update the Gemfile.
2. Add `ruby_llm`, if you use the default RubyLLM adapter.
3. Update workflows to `Agent.new(orchestrator: true)`.
4. Rename `Agent#run`, run accessors, and `TurnKit.default_model` call sites.
5. Update custom tools, sub-agents, clients, stores, cost rates, and Rails store
   configuration.
6. Add the `output_data` migration if your Rails tables do not have it.
7. Run the test suite and at least one real model smoke test for each configured
   adapter.

Useful searches:

```sh
rg "TurnKit::Workflow|TurnKit\.model|run\.output|run\.tool_calls|run\.steps|turnkit_context|structured\?|cached_input|cache_creation|reasoning|system_prompt_contributors|model_prompt_contributors|PromptContribution|conversation_record_class|turn_record_class|message_record_class|tool_execution_record_class"
```

After the code compiles, run:

```sh
bundle exec rake test
```
