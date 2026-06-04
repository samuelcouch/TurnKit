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
# or OPENAI_API_KEY=..., GEMINI_API_KEY=..., OPENROUTER_API_KEY=...
```

TurnKit uses RubyLLM by default. Choose the provider by choosing a RubyLLM model name:

```ruby
TurnKit.default_model = "claude-sonnet-4-5" # Anthropic
# TurnKit.default_model = "gpt-4.1-mini"    # OpenAI
# TurnKit.default_model = "gemini-2.5-flash" # Gemini
```

You can also override the model per agent or per run.

To use a different model SDK, provide a client object that responds to `chat`:

```ruby
class MyClient < TurnKit::Client
  def chat(model:, messages:, tools:, instructions:, temperature: nil, metadata: nil)
    # Call your provider here.
    TurnKit::Result.new(text: "provider response", model: model)
  end
end

TurnKit.client = MyClient.new
```

Ask an agent:

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

List available skills:

```ruby
research = TurnKit::Skill.from_file(
  "skills/research.md",
  description: "Use for source-backed research tasks."
)

agent = TurnKit::Agent.new(
  name: "researcher",
  instructions: "Prefer primary sources.",
  tools: [WebSearch, ReadWebPage],
  available_skills: [research]
)
```

Add subject context:

```ruby
article = Article.find(1)
conversation = agent.conversation(subject: article)
```

Choose prompt sections:

```ruby
agent = TurnKit::Agent.new(
  name: "writer",
  instructions: "Write plainly.",
  prompt_sections: %i[agent instructions tools environment]
)
```

Build a custom prompt:

```ruby
agent = TurnKit::Agent.new(
  name: "custom",
  instructions: "Answer in JSON.",
  system_prompt: ->(prompt) {
    [
      prompt.agent_section,
      prompt.instructions_section,
      "Return only valid JSON."
    ].compact.join("\n\n")
  }
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
TurnKit.store = TurnKit::ActiveRecordStore.new
TurnKit.default_model = "claude-sonnet-4-5"
TurnKit.timeout = 300
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

Override the model for a single conversation or turn:

```ruby
conversation = agent.conversation(model: "claude-opus-4-1")
turn = conversation.run!(model: "gpt-4.1-mini")
```

| Option | Description |
| --- | --- |
| `default_model` | Set the default RubyLLM model. The model name determines the provider. |
| `client` | Set the model client. Defaults to `TurnKit::Adapters::RubyLLM.new`. |
| `store` | Set the conversation store. |
| `max_iterations` | Limit model calls per turn. |
| `timeout` | Limit seconds per root turn. |
| `max_depth` | Limit sub-agent nesting. |
| `max_tool_executions` | Limit tool calls per root turn. |
| `cost_limit` | Limit cost per root turn. |

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
