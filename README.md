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

turn = agent.conversation.ask("Explain Ruby blocks in one sentence.")
puts turn.output_text
```

## Usage

Choose a model:

```ruby
TurnKit.default_model = "claude-sonnet-4-5"
```

Use OpenAI:

```sh
export OPENAI_API_KEY=...
```

```ruby
TurnKit.default_model = "gpt-4.1-mini"
```

Create a conversation:

```ruby
agent = TurnKit::Agent.new(
  name: "writer",
  instructions: "Write clear release notes."
)

conversation = agent.conversation(subject: "v1 launch")
conversation.say("Mention faster tool execution.")

turn = conversation.run!
puts turn.output_text
```

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

Use a tool:

```ruby
agent = TurnKit::Agent.new(
  name: "reporter",
  instructions: "Save reports when asked.",
  tools: [SaveReport]
)

turn = agent.conversation.ask("Save a short status report.")
puts turn.output_text
```

Add skills:

```ruby
skill = TurnKit::Skill.from_file("skills/research.md")

agent = TurnKit::Agent.new(
  name: "researcher",
  skills: [skill]
)
```

Delegate to sub-agents:

```ruby
writer = TurnKit::Agent.new(
  name: "writer",
  description: "Draft concise copy."
)

editor = TurnKit::Agent.new(
  name: "editor",
  sub_agents: [writer]
)

turn = editor.conversation.ask("Ask the writer for three headlines.")
puts turn.output_text
```

Use prompt caching:

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

Inspect usage:

```ruby
record = TurnKit.store.load_turn(turn.id)
record.fetch("usage")
```

Return usage from custom clients:

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

Split instructions inside custom clients:

```ruby
stable, dynamic = TurnKit::SystemPrompt.split_cache_boundary(instructions)
```

Send `stable` with provider cache controls.

Send `dynamic` as normal prompt content.

Use a custom client:

```ruby
TurnKit.client = MyClient.new
```

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
TurnKit.default_model = "claude-sonnet-4-5"
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
| `max_depth` | Limit sub-agent nesting. |
| `max_tool_executions` | Limit tool calls per root turn. |
| `cost_limit` | Limit cost per root turn. |
| `prompt_cache` | Use provider prompt caching. |
| `prompt_sections` | Set default prompt sections. |

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
