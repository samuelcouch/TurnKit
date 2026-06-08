# Upgrade Guide

This guide covers migrating to the newer task-runtime API. The changes are
mostly additive: existing `Agent`, `Conversation`, `Tool`, and `Fleet` code
should continue to work. The recommended migration is about improving developer
experience and making autonomous workflows easier to read.

## Quick summary

You do **not** need to rewrite existing code immediately.

Recommended new forms:

```ruby
TurnKit.configure do |config|
  config.model = "gpt-5.2"
  config.max_spend = 0.25
end

fleet = TurnKit.fleet("brief_writer", tools: [WebSearch, SaveBrief])
run = fleet.run("Create a source-grounded brief.", input: { topic: "Rails 8" })

puts run.output
```

Old forms still work:

```ruby
TurnKit.default_model = "gpt-5.2"

fleet = TurnKit::Fleet.new(name: "brief_writer", tools: [WebSearch, SaveBrief])
run = fleet.run(task: "Create a source-grounded brief.", input: { topic: "Rails 8" })

puts run.output_text
```

## Configuration

### Model name

Before:

```ruby
TurnKit.default_model = "gpt-5.2"
```

After:

```ruby
TurnKit.model = "gpt-5.2"
```

`TurnKit.default_model` remains supported. `TurnKit.model` is the shorter public
alias for app code and initializers.

### Global setup

Before:

```ruby
TurnKit.default_model = "gpt-5.2"
TurnKit.cost_limit = 0.25
TurnKit.max_iterations = 12
```

After:

```ruby
TurnKit.configure do |config|
  config.model = "gpt-5.2"
  config.max_spend = 0.25
  config.max_iterations = 12
end
```

`TurnKit.configure` simply yields the `TurnKit` module. There is no separate
configuration object or DSL.

### Spend limit naming

Before:

```ruby
TurnKit.cost_limit = 0.25
```

After:

```ruby
TurnKit.max_spend = 0.25
```

`cost_limit` remains supported. Prefer `max_spend` in application-facing code
because it matches how developers think about autonomous runs.

## Running application tasks

### Agent tasks

Before:

```ruby
run = agent.run(task: "Classify this lead.", input: lead.attributes)
puts run.output_text
```

After:

```ruby
run = agent.run("Classify this lead.", input: lead.attributes)
puts run.output
```

The keyword form still works. The positional string is the recommended form for
the common case.

### Pending runs

No behavior change.

```ruby
run = agent.run("Classify later.", async: true)
request = run.preview
run.run!
```

The existing keyword form remains valid:

```ruby
run = agent.run(task: "Classify later.", async: true)
```

## Fleets

The fleet mental model changed from “many agents” to “one reusable autonomous
task runtime.” A fleet packages:

- one task-mode orchestrator
- workflow skills
- tools
- guardrails
- compaction
- optional persistence/action tools

### Construction

Before:

```ruby
fleet = TurnKit::Fleet.new(
  name: "sales_enrichment",
  tools: [AccountLookup, WebSearch, SaveEnrichment],
  skills: [sales_research_skill],
  max_spend: 0.25
)
```

After:

```ruby
fleet = TurnKit.fleet(
  "sales_enrichment",
  tools: [AccountLookup, WebSearch, SaveEnrichment],
  skills: [sales_research_skill],
  max_spend: 0.25
)
```

`TurnKit::Fleet.new` remains supported.

### Running

Before:

```ruby
run = fleet.run(
  task: "Enrich this account for responsible outreach.",
  input: account.attributes
)
```

After:

```ruby
run = fleet.run(
  "Enrich this account for responsible outreach.",
  input: account.attributes
)
```

`task:` remains supported.

### Auto-run alias

No behavior change.

```ruby
run = fleet.auto_run("Enrich this account.", input: account.attributes)
```

Use `auto_run` when the name helps communicate that the fleet should navigate
from input to output on its own. It is an alias for `run`.

## Run inspection

New convenience methods were added to `TurnKit::Run`.

Before:

```ruby
run.output_text
run.tool_executions
run.turn_records.length
TurnKit.store.load_turn(run.id)["error"]
```

After:

```ruby
run.output
run.tool_calls
run.steps
run.error
```

Old methods remain available. Prefer the shorter methods in application code,
examples, and docs.

## Save/action tools

Use `terminal!` for tools that complete the run by saving an artifact or taking
the final action.

Before:

```ruby
class SaveBrief < TurnKit::Tool
  def self.ends_turn? = true
  def self.completion_message(result) = "Saved #{result.fetch("id")}."

  def call(title:, body:, context:)
    { "id" => Brief.create!(title: title, body: body).id }
  end
end
```

After:

```ruby
class SaveBrief < TurnKit::Tool
  terminal! { |result| "Saved #{result.fetch("id")}." }

  def call(title:, body:, context:)
    { "id" => Brief.create!(title: title, body: body).id }
  end
end
```

The old `ends_turn?` and `completion_message` methods remain supported. Prefer
`terminal!` for readability.

## Tool instances

If a tool needs constructor arguments, register an instance instead of a class.

Before, this may have failed at runtime:

```ruby
class WebSearch < TurnKit::Tool
  def initialize(client:)
    @client = client
  end
end

agent = TurnKit::Agent.new(tools: [WebSearch])
```

After:

```ruby
client = SearchClient.new(api_key: ENV.fetch("SEARCH_API_KEY"))
agent = TurnKit::Agent.new(tools: [WebSearch.new(client: client)])
```

This is the recommended pattern for API clients, test doubles, and per-tenant
dependencies.

## Multi-agent fleets

If you previously modeled every role as a separate agent, consider migrating the
default path to one fleet with a workflow skill.

Before:

```ruby
researcher = TurnKit::Agent.new(name: "researcher", tools: [WebSearch])
writer = TurnKit::Agent.new(name: "writer")
verifier = TurnKit::Agent.new(name: "verifier")

orchestrator = TurnKit::Agent.new(
  name: "orchestrator",
  sub_agents: [researcher, writer, verifier]
)
```

After:

```ruby
workflow = TurnKit::Skill.new(
  key: "source_grounded_brief",
  name: "Source Grounded Brief",
  content: <<~TEXT
    Research first. Build an evidence pack. Draft only from evidence. Verify
    important claims. Revise unsupported claims before final output.
  TEXT
)

fleet = TurnKit.fleet(
  "source_brief",
  skills: [workflow],
  tools: [WebSearch, ReadWebPage, SaveBrief],
  max_spend: 0.25,
  max_tool_executions: 20
)
```

Keep separate agents when the isolation is worth the extra model calls:

- different models
- different tool permissions
- adversarial review
- parallel specialist research
- separate durable child conversations

## Suggested migration order

1. Replace `TurnKit.default_model =` with `TurnKit.model =` in app-level config.
2. Wrap global settings in `TurnKit.configure` if you have more than one.
3. Replace `TurnKit::Fleet.new(name: ...)` with `TurnKit.fleet("...")` in new code.
4. Replace `run(task: "...")` with `run("...")` where it improves readability.
5. Replace `run.output_text` with `run.output` in application code.
6. Replace save/action tool overrides with `terminal!` when convenient.
7. Consider collapsing role-agent fleets into one fleet plus workflow skills if
   cost or complexity is a concern.

None of these steps are required for existing code to keep working.
