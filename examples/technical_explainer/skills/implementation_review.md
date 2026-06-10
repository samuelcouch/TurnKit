---
name: Implementation Review
description: Translate source material into implementation boundaries, risks, and tests.
---

# Implementation Review

Use this skill when the user asks what a source document means for a concrete
implementation, library, adapter, test plan, or architecture.

## Triggers

- turn that into an implementation checklist
- what does this mean for Ruby?
- how would we implement this?
- what are the risks for a library author?

## Tools

- `list_saved_briefs`
- `save_implementation_concern`
- `save_research_brief`

## Phases

1. Reuse existing extracted document and brief context when available.
2. Translate source-backed concepts into API boundaries, data structures,
   failure modes, and tests.
3. Flag where the source material does not prescribe implementation details.
4. Save new concerns or a follow-up brief if the review produces durable output.

## Anti-patterns

- Do not make a design requirement sound source-mandated unless the source says it.
- Do not add unnecessary architecture layers.
- Do not ignore testing, error handling, compatibility, or state management.
