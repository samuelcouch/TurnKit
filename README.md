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

Set a provider key. TurnKit uses RubyLLM under the hood and defaults to Anthropic Claude:

```sh
export ANTHROPIC_API_KEY=...
```

| Provider | Env var | Example model |
| --- | --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5` |
| OpenAI | `OPENAI_API_KEY` | `gpt-4.1-mini` |
| Gemini | `GEMINI_API_KEY` | `gemini-2.5-flash` |

> [!WARNING]
> TurnKit defaults to `claude-sonnet-4-5`. If `ANTHROPIC_API_KEY` is unset or blank, set `TurnKit.default_model` to a provider you have configured.

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

Use Gemini:

```sh
export GEMINI_API_KEY=...
```

Set a Gemini model:

```ruby
TurnKit.default_model = "gemini-2.5-flash"
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

#### Defining application tools

Tools are classes, not instances. Namespaced tools work fine, and the default tool name comes from the class name: `Assistant::Tools::WebSearch` becomes `web_search`.

```ruby
module Assistant
  module Tools
    class WebSearch < TurnKit::Tool
      description "Search the web for current information."
      usage_hint "Use when current external information is needed."

      parameter :objective, :string, required: true
      parameter :search_queries, :array, required: false

      def call(objective:, search_queries: nil, context:)
        ParallelClient.new.web_search(
          objective: objective,
          search_queries: search_queries
        )
      end
    end
  end
end
```

Register tool classes on the agent:

```ruby
agent = TurnKit::Agent.new(
  name: "researcher",
  tools: [
    Assistant::Tools::WebSearch,
    Assistant::Tools::ReadWebPage
  ]
)
```

#### Tool context

Every tool receives a `context:` object. Use it for logging, correlation, persistence, and domain scoping:

```ruby
def call(query:, context:)
  context.turn       # The TurnKit::Turn being run
  context.execution  # The TurnKit::ToolExecution for this tool call

  { query: query }
end
```

If your application already uses a `context:` keyword for something else, use `turnkit_context:` instead:

```ruby
def call(query:, turnkit_context:)
  { turn_id: turnkit_context.turn.id, query: query }
end
```

#### Tool return values

Prefer returning a `Hash`. TurnKit serializes the normalized value as the tool result:

| Return value | Stored tool result |
| --- | --- |
| `Hash` | Keys are stringified. |
| `Array` | Wrapped as `{ "items" => [...] }`. |
| Scalar | Wrapped as `{ "result" => value.to_s }`. |

Avoid returning arbitrary objects unless you convert them to a plain Hash or Array first.

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

The installer creates:

- `config/initializers/turnkit.rb`
- `app/models/turnkit/conversation.rb`
- `app/models/turnkit/turn.rb`
- `app/models/turnkit/message.rb`
- `app/models/turnkit/tool_execution.rb`
- a migration for TurnKit persistence

The generated migration currently uses `ActiveRecord::Migration[7.1]`. In a newer Rails app, update that version if your app requires it, for example `ActiveRecord::Migration[8.1]`.

Run migrations:

```sh
bin/rails db:migrate
```

Configure Rails:

```ruby
TurnKit.store = TurnKit::ActiveRecordStore.new
```

Suggested Rails file layout for your application AI code:

```text
app/models/assistant/
  tools/
    web_search.rb
    read_web_page.rb
  skills/
  prompts/
```

If you prefer to keep AI infrastructure out of `app/models`, add an autoloaded directory such as:

```text
app/ai/
  tools/
  skills/
  prompts/
```

Reconcile stale turns:

```ruby
TurnKit.reconcile_stale!
```

#### Debugging Rails persistence

Inspect the latest persisted turn in a Rails console:

```ruby
turn = Turnkit::Turn.order(created_at: :desc).first
turn.status
turn.error
turn.output_text
```

Check whether the model actually called tools:

```ruby
Turnkit::ToolExecution
  .where(turn_uid: turn.uid)
  .order(:created_at)
  .map { |execution|
    {
      name: execution.tool_name,
      status: execution.status,
      arguments: execution.arguments,
      result_keys: execution.result&.keys,
      error: execution.error
    }
  }
```

#### Live smoke test

Use a model whose provider key is configured, then run a real tool-using turn:

```ruby
TurnKit.default_model = "gpt-4.1-mini"

agent = TurnKit::Agent.new(
  name: "researcher",
  instructions: "Use web_search, then read_web_page, before answering.",
  tools: [
    Assistant::Tools::WebSearch,
    Assistant::Tools::ReadWebPage
  ]
)

turn = agent.conversation.ask(
  "Search for the TurnKit Ruby gem, read the first useful result, then summarize it."
)

puts turn.output_text

pp Turnkit::ToolExecution
  .where(turn_uid: turn.id)
  .order(:created_at)
  .pluck(:tool_name, :status, :error)
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
