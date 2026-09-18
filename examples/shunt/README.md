# Shunt: route bulk I/O to a cheaper worker model

A TurnKit port of Spotify's [shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt)
plugin (see the [engineering post](https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90)).
Most of what a coding agent does is reading files, not reasoning. This example
sends that reading to a cheap worker model and hands the primary model only the
answer, so the file bytes never enter the expensive context.

```sh
# Configure ANTHROPIC_API_KEY and GEMINI_API_KEY through Amp secrets.
bundle exec ruby examples/shunt/shunt.rb \
  "What does lib/turnkit/turn.rb do, and which methods write to the store?"
```

`TURNKIT_MODEL` (default `claude-sonnet-5`) is the primary model,
`SHUNT_WORKER_MODEL` (default `gemini-2.5-flash`) the worker, `SHUNT_ROOT` the
project root (default: current directory), `SHUNT_MIN_LINES` the read threshold
(default 350), and `TURNKIT_MAX_SPEND` the observed spend limit (default $1.00).
Stdout is the answer; stderr reports the delegation savings estimate, tool
names, tokens and observed cost.

## Three layers

1. **Tool policy (hard gate).** `tool_policy:` on the primary agent blocks a full
   `read_file` of a file over the threshold and names the alternative:
   "Use `bulk_read`; re-read with `offset`/`limit` for the section you will edit."
   Targeted reads pass because editing needs exact lines the worker cannot supply.
2. **Tools (transport).** `BulkRead` and `CodeWrite` subclass
   `TurnKit::SubAgentTool`, declare typed parameters, and build the worker's task
   in `task_for`. The tool reads the files; the primary model never does.
   `code_write` requires a reference file, and the worker writes the result to
   disk with a terminal `write_file` tool, so generated code never returns to the
   parent either.
3. **Skill (soft guidance).** [`skills/bulk-reader.md`](skills/bulk-reader.md)
   says when to delegate and what not to delegate: debugging, architecture,
   and line-precise edits stay with the primary model.

## Measuring savings

`Shunt::Savings` subscribes to `sub_agent.delegated` (`task_chars` sent to the
worker) and the matching `tool_call.completed` (`result_chars` returned), both
keyed by tool-call ID. It reports `delegated_tokens`, `returned_tokens` and
`saved`, using the same `chars / 4` estimate as TurnKit's compaction. This is
the primary-context input the delegation avoided; it excludes the worker's own
cost, which `run.cost` includes. Delegation below the threshold costs more than
it saves: each call is a full worker round trip.

Run `bundle exec ruby -Itest test/shunt_test.rb` for the fake-client
regressions. They prove the parent's model requests never contain file bytes,
the gate's decisions at and around the threshold, and that `code_write` returns
only the written path.
