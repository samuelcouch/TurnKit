# TurnKit

Durable Ruby AI agent turns, tools, skills, sub-agents, and conversations.

```ruby
agent = TurnKit::Agent.new(
  name: "researcher",
  model: "claude-sonnet-4-5",
  instructions: "You are careful.",
  tools: [ SaveReport ],
  skills: [ TurnKit::Skill.from_file("skills/research.md") ]
)

turn = agent.conversation.ask("Research this and save the report.")
```
