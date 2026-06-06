# TurnKit

[![Gem Version](https://badge.fury.io/rb/turnkit.svg)](https://rubygems.org/gems/turnkit)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-red.svg)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)

Build durable Ruby AI agents with turns, tools, skills, and Rails persistence.

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

Set a provider key:

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

Set the default model:

```ruby
TurnKit.default_model = "claude-sonnet-4-5"
```

Use OpenAI:

```sh
export OPENAI_API_KEY=...
```

Set an OpenAI model:

```ruby
TurnKit.default_model = "gpt-4.1-mini"
```

### Conversations

Create a conversation:

```ruby
agent = TurnKit::Agent.new(
  name: "writer",
  instructions: "Write clear release notes."
)
```

Add context:

```ruby
conversation = agent.conversation(subject: "v1 launch")
conversation.say("Mention faster tool execution.")
```

Run the agent:

```ruby
turn = conversation.run!
puts turn.output_text
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
  def self.completion_message(result) = "Saved #{result.fetch("report_id")}."

  def call(title:, body:, context:)
    { report_id: "rep_1", title: title, body: body }
  end
end
```

Use the tool:

```ruby
agent = TurnKit::Agent.new(
  name: "reporter",
  instructions: "Save reports when asked.",
  tools: [SaveReport]
)
```

Ask for tool use:

```ruby
turn = agent.conversation.ask("Save a short status report.")
puts turn.output_text
```

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

Delegate to it:

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

### Usage and costs

Inspect token usage:

```ruby
turn.usage.total_tokens
conversation.usage.total_tokens
agent.usage.total_tokens
```

Inspect costs:

```ruby
turn.cost.total
conversation.cost.total
agent.cost.total
```

Use RubyLLM registry prices by default.

Override model rates:

```ruby
TurnKit.cost_rates = {
  "my-model" => {
    input: 0.25,
    output: 1.00,
    cached_input: 0.05,
    cache_creation: 0.25
  }
}
```

Override cost calculation:

```ruby
TurnKit.cost_calculator = ->(usage, model) do
  {
    input: usage.input_tokens * 0.25 / 1_000_000.0,
    output: usage.output_tokens * 1.00 / 1_000_000.0
  }
end
```

Limit turn cost:

```ruby
agent = TurnKit::Agent.new(
  name: "analyst",
  cost_limit: 0.25
)
```

### Prompt caching

Enable prompt caching:

```ruby
TurnKit.prompt_cache = :auto
```

Disable prompt caching:

```ruby
TurnKit.prompt_cache = :off
```

Split custom prompts:

```ruby
agent = TurnKit::Agent.new(
  name: "cached",
  system_prompt: [
    "Stable instructions and tool guidance.",
    TurnKit::SystemPrompt::CACHE_BOUNDARY,
    "Dynamic subject and live context."
  ].join("\n")
)
```

### Custom clients

Create a client:

```ruby
class MyClient < TurnKit::Client
  def chat(model:, messages:, tools:, instructions:, temperature: nil, metadata: nil)
    TurnKit::Result.new(
      text: "provider response",
      model: model,
      usage: TurnKit::Usage.new(
        input_tokens: 100,
        output_tokens: 20,
        cached_tokens: 80,
        cache_write_tokens: 100
      )
    )
  end
end
```

Use the client:

```ruby
TurnKit.client = MyClient.new
```

Split cache sections:

```ruby
stable, dynamic = TurnKit::SystemPrompt.split_cache_boundary(instructions)
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

Configure Rails:

```ruby
TurnKit.store = TurnKit::ActiveRecordStore.new
```

Reconcile stale turns:

```ruby
TurnKit.reconcile_stale!
```

## Options

Configure defaults:

```ruby
TurnKit.default_model = "claude-sonnet-4-5"
TurnKit.max_iterations = 25
TurnKit.timeout = 300
TurnKit.max_depth = 3
TurnKit.max_tool_executions = 100
TurnKit.cost_limit = nil
TurnKit.cost_rates = {}
TurnKit.cost_calculator = nil
TurnKit.prompt_cache = :auto
```

Override an agent:

```ruby
agent = TurnKit::Agent.new(
  name: "analyst",
  model: "gpt-4.1-mini",
  max_iterations: 10,
  timeout: 60,
  cost_limit: 0.25
)
```

| Option | Description |
| --- | --- |
| `default_model` | Set the default RubyLLM model. |
| `client` | Set the model client. |
| `store` | Set the conversation store. |
| `max_iterations` | Limit model calls per turn. |
| `timeout` | Limit seconds per root turn. |
| `max_tool_executions` | Limit tool calls per root turn. |
| `cost_limit` | Limit cost per root turn. |
| `cost_rates` | Override prices by model. |
| `cost_calculator` | Override cost calculation. |
| `prompt_cache` | Use provider prompt caching. |

## Contributing

Report bugs and open pull requests on GitHub:

```text
https://github.com/samuelcouch/turnkit
```

Run tests:

```sh
bundle exec rake test
```

## License

See the MIT License.
