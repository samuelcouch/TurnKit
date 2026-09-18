---
name: bulk-reader
description: Delegate reading files over 350 lines, or questions spanning 3+ files, to bulk_read. Not for debugging, editing, or line-precise work.
---
Call `bulk_read` with one specific question and the paths. Each call is
independent: ask a follow-up by sending the same paths again; they go to the
worker, not into your context.

Worker summaries are for understanding. Before editing, verify exact lines or
values with `read_file` and an `offset`/`limit` for just that section.

Use `code_write` when most of a new file follows an existing file's patterns
(tests, config, stubs). Always name a reference file. Afterwards, review the
written file with a targeted read and make only the edits that need judgment.

Never delegate debugging, architectural decisions, or safety-critical code.
