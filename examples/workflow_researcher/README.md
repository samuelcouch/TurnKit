# Workflow Researcher Example

This example shows the recommended TurnKit workflow pattern:

```text
workflow = one task-mode orchestrator + workflow skill + reusable tools + guardrails
```

It intentionally does **not** create separate `researcher`, `writer`, and
`verifier` agents. Those roles are taught by a workflow skill and executed in one
conversation with normal TurnKit tool calls.

It demonstrates:

- `TurnKit::Workflow`
- workflow skills as reusable orchestration patterns
- tool instances with constructor-injected clients
- `max_spend`, `max_iterations`, and `max_tool_executions` guardrails
- `max_tool_executions_by_name` per-tool budgets
- compaction configuration
- web search plus single-page and batch page-reading tools
- deep monitoring for events, turns, tools, usage, and messages

## Setup

Use OpenAI or any RubyLLM-supported provider:

```sh
export OPENAI_API_KEY=...
export TURNKIT_MODEL=gpt-5.2
```

The web tools use Parallel:

```sh
export PARALLEL_API_KEY=...
```

If `PARALLEL_API_KEY` is missing, the run can start, but web search and page
reading tool calls will fail with a clear error.

## Run

Basic run:

```sh
bundle exec ruby examples/workflow_researcher/workflow_researcher.rb \
  "Create a source-grounded brief on Rails 8 Solid Queue for a Rails founder."
```

A more complex run:

```sh
TURNKIT_MAX_SPEND=0.75 \
TURNKIT_MAX_ITERATIONS=25 \
TURNKIT_MAX_TOOL_EXECUTIONS=50 \
bundle exec ruby examples/workflow_researcher/workflow_researcher.rb \
  "Create a source-grounded 10 bullet brief on the Rails 8 Solid Queue docs for a Rails founder. Include at least 5 bullets on who wrote Solid Queue and what inspired it. Fact-check every claim."
```

Add deep monitoring:

```sh
DEEP_MONITORING=1 bundle exec ruby examples/workflow_researcher/workflow_researcher.rb \
  "Create a source-grounded brief on Rails 8 Solid Queue for a Rails founder."
```

## How the workflow works

The workflow packages a single orchestrator runtime:

```ruby
source_grounded_brief = TurnKit::Skill.new(
  key: "source_grounded_brief",
  name: "Source Grounded Brief",
  content: "Research, build an evidence pack, draft, verify, revise, finalize."
)

workflow = TurnKit::Workflow.new(
  name: "source_brief_orchestrator",
  skills: [source_grounded_brief],
  tools: WorkflowResearcher.web_tools,
  max_spend: 0.50,
  max_iterations: 15,
  max_tool_executions: 30,
  max_tool_executions_by_name: {
    web_search: 3,
    read_web_page: 8,
    read_web_pages: 2
  },
  compaction: { context_limit: 64_000, threshold: 0.75 }
)

run = workflow.run(
  "Create a source-grounded brief for the request.",
  input: { request: request }
)

puts run.output
```

The model stays in one conversation and uses the regular TurnKit loop:

```text
model → web_search → result → read_web_pages → result → final
```

## Tool dependency injection

The web tools are plain Ruby objects. They build their client from
`PARALLEL_API_KEY` by default, and can also receive an injected client for tests
or custom configuration:

```ruby
tools = WorkflowResearcher.web_tools

# or
client = WorkflowResearcher::ParallelClient.new(api_key: "...")
tools = WorkflowResearcher.web_tools(parallel_client: client)
```

## When to use separate agents

Use separate agents or `sub_agents` only when the isolation is worth the extra
model calls, such as different models, different tool permissions, parallel
specialist review, or separate durable child conversations.
