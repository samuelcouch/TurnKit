# TurnKit

[![Gem Version](https://badge.fury.io/rb/turnkit.svg)](https://rubygems.org/gems/turnkit)
[![Build](https://github.com/samcouch/turnkit/actions/workflows/ci.yml/badge.svg)](https://github.com/samcouch/turnkit/actions)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-red.svg)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE.md)

Ruby AI agent runtime with durable turns, tools, skills, and Rails persistence.

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

Set a provider key, then ask an agent:

```sh
export ANTHROPIC_API_KEY=...
```

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

Install Rails persistence:

```sh
bin/rails generate turnkit:install
bin/rails db:migrate
```

Configure Rails:

```ruby
# config/initializers/turnkit.rb
TurnKit.store = TurnKit::ActiveRecordStore.new
TurnKit.default_model = "claude-sonnet-4-5"
TurnKit.timeout = 300
```

Reconcile stale turns:

```ruby
TurnKit.reconcile_stale!
```

## Options

Configure defaults globally:

```ruby
TurnKit.default_model = "claude-sonnet-4-5"
TurnKit.max_iterations = 25
TurnKit.timeout = 300
TurnKit.max_depth = 3
TurnKit.max_tool_executions = 100
TurnKit.cost_limit = nil
```

Override defaults per agent:

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
| `default_model` | Default model for new turns. |
| `client` | Client adapter for model calls. |
| `store` | Store for conversations and turns. |
| `max_iterations` | Maximum model calls per turn. |
| `timeout` | Maximum seconds per root turn. |
| `max_depth` | Maximum sub-agent nesting depth. |
| `max_tool_executions` | Maximum tool calls per root turn. |
| `cost_limit` | Maximum cost per root turn. |

## Contributing

Open bug reports and pull requests on GitHub:

```text
https://github.com/samcouch/turnkit
```

Run tests:

```sh
bundle exec rake test
```

## License

See the MIT License.
