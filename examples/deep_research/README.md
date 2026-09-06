# Deep research: adjacent ideas, independent threads and skeptical review

A real-provider example for turning an open-ended question into **three source-backed,
testable ideas**. All four agents use **Claude Sonnet 5 with high thinking**. Parallel
provides web search and source extraction. There is no fake mode in this CLI.

## Research process

1. The coordinator records questions and competing hypotheses.
2. It launches `deep_adjacent` as an independent background turn to research two adjacent fields.
3. It delegates direct evidence research to `deep_evidence` while the adjacent branch works.
4. It joins the independent turn with `wait_for` and compares the two research memos.
5. It supplies draft ideas and evidence to the tool-free `deep_skeptic` subagent.
6. It records each revised idea separately with `record_idea` in slots 1–3. Reusing a slot
   revises that idea; successful tool results persist the versions without another table.
7. `submit_research` assembles JSON from the validated records: research agenda, three ideas,
   mechanisms, adjacent inspirations, evidence URLs, uncertainties, falsifiable experiments,
   sources, research/review memos and open questions.

These are actual TurnKit child conversations and persisted background jobs—not agents merely
described inside a prompt. Three Solid Queue worker threads allow the branches to overlap.
The parent releases its worker while joining. The child agents receive explicit tasks, not
the complete parent transcript. This is not a fresh operating-system sandbox per child.

High thinking enables provider reasoning. Public artifacts are concise questions, hypotheses,
evidence and critiques, **not private chain-of-thought**. The example cannot establish that an
idea is globally unique, effective or exhaustive; it explicitly labels novelty as unproven.

## Run in an Amp orb

Requires the repository's Ruby/Bundler/PostgreSQL setup plus `ANTHROPIC_API_KEY` and
`PARALLEL_API_KEY` in Amp secrets. Reuses the durable reference app's schema, Rails boot and
queue configuration in a **separate database**, without duplicating that infrastructure.

```sh
# Once, idempotent; creates the dedicated database if necessary.
TURNKIT_DEMO_DATABASE_URL=postgresql:///turnkit_demo_deep \
  bundle exec ruby examples/durable_research/setup.rb

amp orb service start deep-research \
  --command '/bin/bash -lc "bundle exec ruby examples/deep_research/deep_research.rb worker"'

bundle exec ruby examples/deep_research/deep_research.rb \
  "How could a small public library help residents withstand summer heat? Find three practical, non-obvious interventions inspired by adjacent fields, with low-cost experiments." \
  > research.json 2> verification.log

amp orb service stop deep-research
```

Without a topic argument the CLI uses that library/heat question. Stdout is report JSON;
stderr prints the persisted turn ID and final verification metadata. Outside an orb, run
the `worker` command under your process supervisor and the research command separately.
Use the same database, model and budget environment for both processes.

`TURNKIT_MODEL` selects another model supporting high thinking **with tools**; there is no
silent reasoning downgrade. `TURNKIT_MAX_SPEND` defaults to $10 observed model spend shared
across the run tree. It is not a prepaid cap: a request can exceed it, and Parallel charges
are excluded. Root limits are 60 model iterations, 64 tools, 12 searches and 12 source
read batches. Each researcher is instructed to conduct two or three focused search rounds,
read four to six distinct sources and investigate contradictions. Up to two skeptical reviews
are allowed. Extraction returns at most 12,000 characters per source, so a complete-document
audit is outside this example's scope. Read-only research can repeat after a crash and incur
additional API charges.

The coordinator has a 1,200-second deadline. The CLI waits up to 1,260 seconds and reports the
persisted ID on timeout; it does not silently cancel or erase the background work. Stop the
worker or use `TurnKit.load_turn(id).cancel!` in the configured application when appropriate.
Jobs survive the submitting process, but this CLI waits so it can validate and export results.

## What is verified

- Submission requires all three child agents to have completed.
- Both research branches must have successful Parallel search and source-read tool executions.
- Questions, detached launch and explicit wait must have completed before final submission.
- Every idea must cite successfully extracted URLs and include uncertainty and an experiment.
- All three idea slots must be recorded before final submission; an invented citation returns
  the exact available source URLs so the model can correct it without blind guessing.
- The CLI checks that the two research branches' persisted execution intervals overlap.
  This measures overlapping branch work, **not necessarily overlapping HTTP requests**.

Unpaid regression: `bundle exec ruby -Itest test/deep_research_test.rb` uses fake provider
responses with the real background coordination runtime. It verifies the full orchestration,
high-thinking request configuration, separate conversations and rejection of invented citations.
The live CLI verifies actual provider calls; citation provenance is not a guarantee of factual
accuracy or idea quality. Review the research before acting, particularly health-related advice.

## Rare-earth legislation and company scenario report

Set `TURNKIT_RESEARCH_REPORT=rare_earth` in **both** worker and submitting process.
This selects a separate report contract, not the three-idea template; the default library
topic and its tests remain unchanged. The current local calendar date anchors an exact
90-day horizon. “Publicly traded” means US-exchange-listed (NYSE, NYSE American, Nasdaq),
not OTC or private companies. Coverage is evidence-led and non-exhaustive.

After `.agents/setup` and `amp orb services ensure`, prepare the dedicated database above.
If the local `user` role lacks CREATEDB, first run
`sudo -u postgres createdb -O user turnkit_demo_deep` (once), then the schema setup command.
Non-login tool shells may need `source ~/.bash_profile` after setup to find Ruby/Bundler.

```sh
amp orb service start rare-earth-research \
  --command '/bin/bash -lc "TURNKIT_RESEARCH_REPORT=rare_earth TURNKIT_MAX_SPEND=10 bundle exec ruby examples/deep_research/deep_research.rb worker"'

TURNKIT_RESEARCH_REPORT=rare_earth TURNKIT_MAX_SPEND=10 \
  TURNKIT_REPORT_MARKDOWN=rare-earth-report.md \
  bundle exec ruby examples/deep_research/deep_research.rb \
  > rare-earth-report.json 2> rare-earth-verification.log

amp orb service stop rare-earth-research
```

The independent adjacent branch owns company filings/IR plus defense procurement and trade/
financing transmission; the evidence subagent owns primary legislation/regulation. Each is
instructed to alternate at most four searches with six extraction batches; the shared hard
limits allow 12 searches, 12 extraction batches, 64 tools and 60 iterations. The coordinator
joins both, can extract missing primary evidence within that same shared limit, and supplies
its draft to a skeptical reviewer. Obvious access-block pages are rejected. All use high thinking.

Incremental `record_policy` and `record_company` calls validate nonempty fields, policy-status
and exchange enums, and exact extracted citation URLs. Reusing a name/ticker revises its record.
The terminal tool requires completed children, search/extraction in both branches, explicit
launch/join, and nonempty policy/company records. The CLI validates the assembled JSON against
`RareEarthResearch.report_schema` and checks branch execution overlap (not HTTP overlap).
Markdown is a deterministic rendering of that JSON. Policy records distinguish enacted law,
pending bills, executive actions and regulations. Company records include dated verification,
rare-earth exposure, uncertainty, and conditional downside/base/upside business consequences
and triggers—not probabilities, stock-price targets or guarantees.

Schema and citation validation establish structure and retrieval provenance, **not factual
truth or present-day listing/legal status**. Extraction is excerpt-limited. The report must
disclose stale sources, missing status verification, exclusions and horizon limits. Review it
before acting; it is not investment advice. A failed run still incurs costs; subtract its
observed model spend from any authorized allowance before retrying. Parallel charges remain
excluded, and the observed model cap can be exceeded by an in-flight request.

Unpaid regression: `bundle exec ruby -Itest test/rare_earth_research_test.rb` also runs the
unchanged library-topic tests and checks incremental revision, missing-review rejection,
invented-citation rejection, the report schema, date horizon and Markdown contents.
