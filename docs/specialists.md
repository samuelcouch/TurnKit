# Specialists

`TurnKit::Specialists` provides minimal factories for three first-party specialists. Each factory returns a normal `TurnKit::Agent`; its capabilities are ordinary `TurnKit::Tool` instances, so applications can subclass tools or pass normal agent options. A model is always explicit—there are no private or pinned model names.

```ruby
require "turnkit"
```

## Oracle

```ruby
oracle = TurnKit::Specialists.oracle(
  model: "your-advisor-model",
  root: Rails.root,
  client: MyClient.new,
  instructions: "Prioritize operational risk."
)
result = oracle.run("Review config/limits.yml and recommend safe defaults")
```

By default Oracle receives only a root-confined `ReadFile` tool. Symlinks and `..` cannot escape the configured root. Supplying `tools:` replaces that default, and every supplied class or instance must deterministically implement `read_only?` and return exactly `true`. Extend `TurnKit::Specialists::ReadOnlyTool` for the built-in marker. This validation is capability metadata, not prompt-based authorization; mutation tools are never inherited.

## Librarian

```ruby
librarian = TurnKit::Specialists.librarian(
  repository: "ruby/ruby",
  model: "your-research-model",
  token: ENV["GITHUB_TOKEN"] # optional for public repositories
)
result = librarian.run("How did timeout handling change between v3_3_0 and v3_4_0?")
```

Its read-only GitHub tool supports repository/default-branch metadata, file contents at an optional ref, commit history, comparisons/diffs, issue lists, and individual issues. It is permanently scoped to the validated `owner/name`. The stdlib `Net::HTTP` transport only calls HTTPS `api.github.com`, never follows redirects, and exposes no shell or write endpoint. Authentication values are sent in a header and are not included in results. Responses contain `repository`, `operation`, `source`, and `data`, enabling source-backed answers.

Tests can inject `github_client: ->(uri:, headers:) { [status, json_body] }`. `client:` remains the model client; `github_client:` is only the HTTP transport.

## Painter

```ruby
gate = lambda do |request, context:|
  ImagePermissions.allowed?(context.principal, request)
end

painter = TurnKit::Specialists.painter(
  model: "your-tool-calling-chat-model",
  image_model: "your-image-generation-model",
  provider: :your_provider,
  size: "1024x1024",
  params: { quality: "high" },
  max_reference_images: 4, # application/provider configuration
  authorization: gate
)
painter.run("Edit the supplied references into a product hero", principal: authenticated_user.id)
```

Painter's `paint_image` tool forwards its prompt, `reference_images`, and optional `mask` to `Turn#paint`. Its terminal JSON contains `conversation_id`, `image_message_id`, and image metadata, not base64 bytes. Resolve the image message from the configured store to retrieve the persisted artifact. URL-only provider artifacts still require application retention if the provider expires its URLs. The required application-owned callable gate runs immediately before every paid generation; only literal `true` authorizes it. Authorization is not a model-provided argument. `max_reference_images` is optional provider configuration rather than a hard-coded provider limit. No call is made while constructing the specialist.

All factories accept extra `Agent.new` keyword options (for example `thinking:`, `timeout:`, or `max_spend:`), custom `instructions:`, and additional tools where appropriate.

## Extension and isolation

Factories disable global context contributors. Read-only validation also covers skill-owned tools;
unchecked subagents are rejected. A developer's `read_only?` declaration is trusted metadata,
not an OS sandbox: custom Ruby code still has the application's process permissions.
Use these agents directly, register them for durable background execution, or supply them as
ordinary `sub_agents:`. Models, instructions, skills and read capabilities remain application choices.

Skills accept `tools:` in `Skill.new` or `Skill.from_file`. Preloaded `skills:` expose their tools
immediately. `available_skills:` expose metadata and `load_skill`; their tools become callable only
after a successful load in that turn, restored from persisted executions after a restart. Loading
does not grant authorization: the normal tool policy still runs. New turns load independently.

Run the bounded real-provider examples (Anthropic credentials; OpenAI also required for Painter):

```sh
bundle exec ruby examples/specialists/smoke.rb oracle
bundle exec ruby examples/specialists/smoke.rb librarian
TURNKIT_IMAGE_OUTPUT=/tmp/pear.png bundle exec ruby examples/specialists/smoke.rb painter
```

These use high-thinking Claude Sonnet 5 and an observed model-spend limit of $0.50 per run,
not a prepaid billing cap. Librarian uses GitHub's real read API; set `GITHUB_TOKEN` for private
repositories or higher rate limits. Painter uses a separate GPT Image 2 generation model.
