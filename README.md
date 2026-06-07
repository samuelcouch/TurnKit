# TurnKit

[![Gem Version](https://badge.fury.io/rb/turnkit.svg)](https://rubygems.org/gems/turnkit)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-red.svg)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)

Build durable Ruby and Rails agents with tools, skills, sub-agents, and persistence.

## Installation

Add this line to your application's **Gemfile**:

```ruby
gem "turnkit"
```

Run:

```sh
bundle install
```

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

## Usage

### Models

Set a model:

```ruby
TurnKit.default_model = "gpt-4.1-mini"
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

  def self.ends_turn? = true

  def self.completion_message(result)
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
| `TurnKit.timeout` | Limit turn runtime. |
| `TurnKit.cost_limit` | Limit estimated turn cost. |
| `TurnKit.compaction` | Configure context compaction. |
| `TurnKit.on_event` | Subscribe to lifecycle events. |

Set options globally:

```ruby
TurnKit.default_model = "gpt-4.1-mini"
TurnKit.max_iterations = 25
TurnKit.timeout = 300
```

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
