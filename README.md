# TurnKit

[![Gem Version](https://badge.fury.io/rb/turnkit.svg)](https://rubygems.org/gems/turnkit)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-red.svg)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)

Build durable Ruby and Rails agents with conversations, runs, workflows, tools,
skills, output audits, sub-agents, and persistence.

## Installation

Add this line to your application's **Gemfile**:

```ruby
gem "turnkit"
```

Run:

```sh
bundle install
```

Upgrading from an earlier TurnKit version? See the [Upgrade Guide](UPGRADE.md).

## Quick Start

Set an API key:

```sh
export ANTHROPIC_API_KEY=...
```

Create an agent:

```ruby
require "turnkit"

agent = TurnKit::Agent.new(
  name: "helper",
  instructions: "Answer briefly."
)
```

Ask a question:

```ruby
turn = agent.conversation.ask("Explain Ruby blocks in one sentence.")
puts turn.output_text
```

Or run a non-interactive application task:

```ruby
run = agent.run("Explain Ruby blocks in one sentence.")
puts run.output
```

## Usage

For runnable, API-key-free examples of the three core entry points, see
[`examples/core_api`](examples/core_api):

- conversation: durable thread over time;
- agent run: one bounded application task;
- workflow: reusable task runner with skills, tools, and limits.

For fuller workflow examples, see:

- [`examples/workflow_researcher`](examples/workflow_researcher): source-grounded research with web tools, batch reads, per-tool limits, and deep monitoring;
- [`examples/amazon_memo_writer`](examples/amazon_memo_writer): strict memo generation with research tools, a structured terminal submit tool, deterministic format checks, and an LLM output policy.

### Models

Set a model:

```ruby
TurnKit.model = "gpt-4.1-mini"
```

Or configure TurnKit in one place:

```ruby
TurnKit.configure do |config|
  config.model = "gpt-4.1-mini"
  config.max_spend = 0.25
  config.max_iterations = 12
end
```

Set the matching key:

```sh
export OPENAI_API_KEY=...
```

Use these common providers:

| Provider | Key | Model |
| --- | --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5` |
| OpenAI | `OPENAI_API_KEY` | `gpt-4.1-mini` |
| Gemini | `GEMINI_API_KEY` | `gemini-2.5-flash` |
| OpenRouter | `OPENROUTER_API_KEY` | `openrouter/...` |

Expect `TurnKit::ModelAccessError` for obvious key mistakes.

To run eligible coding tasks against a ChatGPT Plus/Pro Codex subscription instead of provider API-key billing, use the Codex adapter. It shells out to the official `codex exec` CLI, so authenticate Codex first:

```sh
codex login --device-auth
```

Then configure TurnKit:

```ruby
TurnKit.configure do |config|
  config.client = TurnKit::Adapters::Codex.new(sandbox: "read-only")
  config.model = "gpt-5.4"
end
```

The Codex adapter does not store ChatGPT tokens or read `~/.codex/auth.json` directly. It reuses Codex CLI auth and records token usage with no TurnKit provider cost, because usage is charged against the user's ChatGPT/Codex plan limits.

### Conversations

Create a conversation:

```ruby
agent = TurnKit::Agent.new(
  name: "writer",
  instructions: "Write clear release notes."
)

conversation = agent.conversation(subject: "v1 launch")
```

Add context:

```ruby
conversation.say("Mention faster tool execution.")
```

Run the agent:

```ruby
turn = conversation.run!
puts turn.output_text
```

### Runs

Use `Agent#run` when your application needs one non-interactive result. A run is
the AI equivalent of a service object call: one input, one job, one output.

Reach for a run when the task is bounded, such as classification, extraction,
summarization, routing, scoring, or structured JSON generation.

```ruby
agent = TurnKit::Agent.new(
  name: "lead_classifier",
  instructions: "Classify leads and return routing data.",
  output_schema: {
    type: "object",
    properties: {
      priority: { type: "string" },
      reason: { type: "string" }
    },
    required: ["priority", "reason"]
  },
)

run = agent.run(
  "Classify this lead.",
  input: { company: "Acme", employees: 1_200 }
)

puts run.output_data
```

`Agent#run` uses task prompt behavior by default: it treats the input as the
contract, avoids follow-up questions, and returns the best result it can. It is a
small wrapper over TurnKit's existing conversation and turn engine. Existing
`conversation.ask` usage is still supported for multi-turn threads.

Prepare a pending run without calling the model:

```ruby
run = agent.run(task: "Classify later.", async: true)
request = run.preview
run.run!
```

### Workflows

Use a workflow when a run graduates into a reusable production capability: a
named task runner with workflow skills, tools, defaults, guardrails, compaction,
and output policy.

Workflows fight for their life when the task has a repeatable operating
procedure: inspect app data, gather context, use sources, draft, verify, save,
and stop under budget. They are overkill for simple classification or extraction
runs.

```ruby
source_grounded_brief = TurnKit::Skill.from_file("app/ai/skills/source_grounded_brief.md")

workflow = TurnKit::Workflow.new(
  name: "brief_writer",
  instructions: "Create source-grounded briefs and verify claims before final output.",
  skills: [source_grounded_brief],
  tools: [WebSearch.new, ReadWebPage.new, SaveBrief],
  max_spend: 0.25,
  max_iterations: 12,
  max_tool_executions: 25,
  max_tool_executions_by_name: {
    web_search: 2,
    read_web_page: 8
  },
  compaction: {
    context_limit: 64_000,
    threshold: 0.75
  }
)

run = workflow.run(
  "Create a source-grounded brief.",
  input: { topic: "Rails 8 Solid Queue" }
)

puts run.output
puts run.tool_calls.map(&:tool_name)
puts run.cost.total
```

This keeps the work in a single conversation and uses TurnKit's normal
model-tool loop:

```text
model → tool → result → model → tool → result → final
```

For repeated workflows, keep instructions, skills, and tools stable and pass the
per-run data through `input:`. This gives provider prompt caching the best chance
to reuse the stable workflow prompt while each run supplies dynamic data.

### Choosing runs, conversations, and workflows

Use the smallest entry point that matches the shape of work:

| Entry point | Use when | Tradeoffs |
| --- | --- | --- |
| `Conversation` | A user or app will keep adding messages over time. | Best for durable threads and follow-up steering; history grows, so long threads need compaction. |
| `Agent#run` | Your app needs one bounded result now. | Best for simple production tasks; repeated complex policies can sprawl across callers. |
| `TurnKit::Workflow` | A task becomes a named reusable workflow with tools, skills, limits, and observability. | Best cache and packaging story for repeated autonomous work; overkill for one-off/simple tasks. |

Prompt caching and compaction solve different problems:

- prompt caching reduces the cost of repeated stable instructions, tools, and
  skills;
- compaction reduces the cost of long dynamic histories;
- budgets (`max_spend`, `max_iterations`, `max_tool_executions`) keep autonomous
  loops bounded.

Use `max_tool_executions_by_name` when a workflow needs different budgets for
different tools. For example, allow many cheap reads but only one final submit
tool, or cap web searches while allowing a batch page reader.

Reach for separate agents and `sub_agents` only when the isolation is worth the
extra model calls, such as different models, different tool permissions,
parallel specialist review, or separate durable child conversations.

Run a workflow with `run`:

```ruby
run = workflow.run(
  "Create compliant outreach for this account.",
  input: lead.attributes,
  max_spend: 0.25,
  max_iterations: 8,
  max_tool_executions: 20,
  compaction: {
    context_limit: 64_000,
    threshold: 0.75
  }
)
```

Use `terminal!` for save or action tools that complete the run:

```ruby
class SaveBrief < TurnKit::Tool
  description "Save the final brief."
  parameter :title, :string, required: true
  parameter :body, :string, required: true

  terminal! { |result| "Saved #{result.fetch("id")}." }

  def call(title:, body:, context:)
    Brief.create!(title: title, body: body).then { |brief| { id: brief.id } }
  end
end
```

### Output audits and policies

Use output audits for deterministic checks that should not depend on another
model call: required headings, source counts, forbidden characters, JSON shape,
or project-specific formatting rules.

```ruby
no_em_dash = ->(output) do
  next unless output.include?("—")

  { rule: "no_em_dash", message: "contains an em dash" }
end

numbered_lists_only = ->(output) do
  lines = output.lines.each_with_index.filter_map do |line, index|
    index + 1 if line.match?(/^\s*[-*]\s+/)
  end

  next if lines.empty?

  {
    rule: "numbered_lists_only",
    message: "contains unordered list markers",
    metadata: { lines: lines }
  }
end

workflow = TurnKit::Workflow.new(
  name: "memo_writer",
  output_policy: [no_em_dash, numbered_lists_only],
  output_policy_mode: :fail
)
```

Run checks directly when you want to test a renderer or policy without calling a
model:

```ruby
audit = TurnKit.check_output_policy(
  "1. Recommendation\n- unordered item — fix this\n",
  constraints: [no_em_dash, numbered_lists_only]
)

puts audit.clean?
puts audit.messages
```

Use `output_policy` when a semantic judge is worth the extra model call. The
policy can be a `.md`, `.markdown`, or `.txt` file path, a `TurnKit::Skill`, a
`TurnKit::OutputPolicy`, or any object that responds to `#call` or `#check`.

```ruby
workflow = TurnKit::Workflow.new(
  name: "memo_writer",
  output_policy: "app/ai/policies/amazon_memo.md",
  output_policy_model: "gpt-4.1-mini",
  output_policy_thinking: { effort: :low },
  output_policy_mode: :report
)
```

`output_policy_mode: :report` records violations while allowing the run to
complete. `:fail` marks the run failed after recording the output and audit;
`:fail` is the default for contract-driven workflows. Policy model usage and
cost are counted on the parent run.

Add `output_retries:` to turn policy failures into bounded revision loops instead
of dead ends:

```ruby
voice = TurnKit::Skill.from_file("app/ai/skills/memo_voice.md")

workflow = TurnKit::Workflow.new(
  name: "memo_writer",
  skills: [voice],
  output_policy: [voice, no_em_dash],
  output_retries: 2,
  input_schema: {
    "type" => "object",
    "required" => ["project_id"],
    "properties" => { "project_id" => { "type" => "string" } }
  }
)
```

`skills:` are always loaded into the prompt. `available_skills:` are listed in
`<skills_available>` and exposed through the `load_skill` tool, so the model can
load full instructions on demand. Every advertised tool call receives exactly one
tool result, including validation errors, budget denials, and calls skipped after
a terminal tool ends the turn.

### Prompt Preview

Preview a pending turn:

```ruby
turn = conversation.ask("Draft the launch email.", async: true)
request = turn.preview
```

Inspect the request:

```ruby
request.model
request.messages
request.tool_names
request.instructions
request.report
```

Run the reviewed turn:

```ruby
turn.run!
```

### Tools

Create a tool:

```ruby
class SaveReport < TurnKit::Tool
  description "Save a report."
  usage_hint "Use when the user asks to persist a report."

  parameter :title, :string, required: true
  parameter :body, :string, required: true

  terminal! do |result|
    "Saved #{result.fetch("report_id")}."
  end

  def call(title:, body:, context:)
    { report_id: "rep_1", title: title, body: body }
  end
end
```

Register the tool:

```ruby
agent = TurnKit::Agent.new(
  name: "reporter",
  instructions: "Save reports when asked.",
  tools: [SaveReport]
)
```

Run the tool loop:

```ruby
turn = agent.conversation.ask("Save a short status report.")
puts turn.output_text
```

Rely on TurnKit to validate tools and model-provided arguments.

### Structured Output

Define a schema:

```ruby
schema = {
  type: "object",
  properties: {
    title: { type: "string" },
    bullets: {
      type: "array",
      items: { type: "string" }
    }
  },
  required: ["title", "bullets"]
}
```

Use structured output:

```ruby
agent = TurnKit::Agent.new(
  name: "writer",
  output_schema: schema
)

turn = agent.conversation.ask("Summarize the launch plan.")
puts turn.output_data
```

Override the schema per turn:

```ruby
conversation.ask(
  "Return one decision.",
  output_schema: {
    type: "object",
    properties: {
      decision: { type: "string" }
    }
  }
)
```

### Events

Subscribe globally:

```ruby
TurnKit.on_event = ->(event) do
  Rails.logger.info("turnkit.#{event.type}")
end
```

Subscribe per agent:

```ruby
agent = TurnKit::Agent.new(
  name: "helper",
  on_event: ->(event) { puts event.type }
)
```

Subscribe per turn:

```ruby
turn.run! do |event|
  puts event.type
end
```

Use events for turns, model calls, messages, and tool calls.

### Skills

Load a skill:

```ruby
skill = TurnKit::Skill.from_file("skills/research.md")
```

Use the skill:

```ruby
agent = TurnKit::Agent.new(
  name: "researcher",
  skills: [skill]
)
```

### Sub-agents

Create a sub-agent:

```ruby
writer = TurnKit::Agent.new(
  name: "writer",
  description: "Draft concise copy."
)
```

Register the sub-agent:

```ruby
editor = TurnKit::Agent.new(
  name: "editor",
  sub_agents: [writer]
)
```

Ask the parent agent:

```ruby
turn = editor.conversation.ask("Ask the writer for three headlines.")
puts turn.output_text
```

Use sub-agents for isolated child conversations.

### Context Compaction

Disable compaction:

```ruby
TurnKit.compaction = false
```

Configure compaction:

```ruby
TurnKit.compaction = {
  model: "gpt-4.1-mini",
  threshold: 0.75,
  context_limit: 128_000
}
```

Compact manually:

```ruby
conversation.compact!(focus: "billing migration")
```

Run the local smoke test:

```sh
ruby script/manual_compaction.rb
```

### Rails

Install Rails persistence:

```sh
bin/rails generate turnkit:install
```

Run migrations:

```sh
bin/rails db:migrate
```

Use this layout:

```text
app/ai/agents/
app/ai/tools/
app/ai/skills/
```

Reconcile stale turns:

```ruby
TurnKit.reconcile_stale!
```

## Options

| Option | Description |
| --- | --- |
| `TurnKit.default_model` | Set the default model. |
| `TurnKit.client` | Set the model client. |
| `TurnKit.store` | Set the persistence store. |
| `TurnKit.max_iterations` | Limit model loop iterations. |
| `TurnKit.max_depth` | Limit sub-agent depth. |
| `TurnKit.max_tool_executions` | Limit tool calls per turn. |
| `TurnKit.max_tool_executions_by_name` | Limit specific tools independently. |
| `TurnKit.timeout` | Limit turn runtime. |
| `TurnKit.max_spend` | Limit estimated turn cost. |
| `TurnKit.compaction` | Configure context compaction. |
| `TurnKit.output_policy_model` | Default model for file-backed output policies. |
| `TurnKit.output_policy_thinking` | Default thinking config for file-backed output policies. |
| `TurnKit.on_event` | Subscribe to lifecycle events. |

Set options globally:

```ruby
TurnKit.default_model = "gpt-4.1-mini"
TurnKit.max_spend = 0.25
TurnKit.max_iterations = 25
TurnKit.max_tool_executions_by_name = { web_search: 2 }
TurnKit.output_policy_model = "gpt-4.1-mini"
TurnKit.timeout = 300
```

`max_spend` is the only spend-limit name in the public API.

Set options per agent:

```ruby
agent = TurnKit::Agent.new(
  name: "engineer",
  model: "gpt-4.1-mini",
  max_iterations: 10,
  max_depth: 2
)
```

Enable thinking:

```ruby
agent = TurnKit::Agent.new(
  name: "reasoner",
  model: "claude-sonnet-4-5",
  thinking: { budget: 4_000 }
)
```

## Upgrading

Add `output_data` for structured output persistence.

```ruby
add_column :turnkit_turns, :output_data, :json
```

Skip this step for new installs.

## Contributing

Fork the project.

Run tests:

```sh
bundle exec rake test
```

Run syntax checks:

```sh
find lib test examples -type f -name '*.rb' -print0 | xargs -0 ruby -c
```

Open a pull request.

## License

Use this gem under the MIT License.
