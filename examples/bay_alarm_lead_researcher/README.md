# Bay Alarm Lead Researcher Example

This example implements a reusable outbound-sales research workflow for a Bay
Alarm salesperson selling commercial security systems in Southern California.

The workflow turns a request like:

```sh
"Find independent auto repair shops in Orange County for Bay Alarm outreach. Target owners or general managers."
```

into a cited lead pack with:

- a vertical research brief;
- FindAll-generated company prospects;
- account-level Bay Alarm fit scoring;
- professional decision-maker candidates;
- strict email provenance rules;
- source-backed outreach angles;
- a rendered Markdown lead pack.

## Why this example exists

This is a production-shaped example for building lead-generation agents with
TurnKit:

```text
GPT-5.5 medium-thinking orchestrator
  -> Parallel Task API for vertical/account/person research
  -> Parallel FindAll for company discovery
  -> Parallel Entity Search for quick people/company lookup
  -> structured terminal save tool for final output
```

It deliberately does **not** rely on the model to invent lead data. The model is
the planner, judge, scorer, and writer; Parallel is the live-web discovery and
research layer. The final save tool enforces basic quality and email-provenance
checks.

## Setup

Use OpenAI or any RubyLLM-compatible provider that supports the configured model:

```sh
export OPENAI_API_KEY=...
export TURNKIT_MODEL=gpt-5.5
export TURNKIT_THINKING_EFFORT=medium
```

The web research tools use Parallel:

```sh
export PARALLEL_API_KEY=...
```

The shared examples also include a Hunter client for direct professional email
discovery and verification:

```sh
export HUNTER_API_KEY=...
```

And an Apollo client for named decision-maker search and enrichment:

```sh
export APOLLO_API_KEY=...
```

The example defaults to quality-first Parallel settings in code:

- `research_vertical`: `ultra` processor.
- `find_companies`: `pro` FindAll generator.
- Account/contact enrichment: `pro` Task processor.

That is intentional for final lead packs. If you want faster/lower-cost iteration,
override the defaults with smaller limits and faster processors:

```sh
export PARALLEL_FINDALL_GENERATOR=preview
export PARALLEL_TASK_PROCESSOR=base-fast
export PARALLEL_DEEP_PROCESSOR=pro-fast
export TURNKIT_MAX_ACCOUNT_ENRICHMENTS=3
export TURNKIT_MAX_CONTACT_SEARCHES=3
```

## Run

Default request:

```sh
bundle exec ruby examples/bay_alarm_lead_researcher/bay_alarm_lead_researcher.rb
```

Custom vertical:

```sh
bundle exec ruby examples/bay_alarm_lead_researcher/bay_alarm_lead_researcher.rb \
  "Find 15 independent dental practices in San Diego County for Bay Alarm commercial security outreach. Target owners, office managers, or operations managers."
```

Narrow geography and exclusions:

```sh
bundle exec ruby examples/bay_alarm_lead_researcher/bay_alarm_lead_researcher.rb \
  "Find 20 cannabis dispensaries and delivery operators in Los Angeles and Orange County. Exclude national chains. Target owners, operators, or compliance managers."
```

Add deep monitoring:

```sh
DEEP_MONITORING=1 bundle exec ruby examples/bay_alarm_lead_researcher/bay_alarm_lead_researcher.rb \
  "Find independent cold-storage warehouses in Southern California for Bay Alarm outreach."
```

## Tool design

The example defines workflow-specific tools instead of exposing raw generic API
calls:

| Tool | Purpose |
| --- | --- |
| `research_vertical` | Parallel Task API vertical brief with structured JSON output. |
| `draft_findall_schema` | Parallel FindAll ingest to draft entity type and match conditions. |
| `find_companies` | Parallel FindAll run for account discovery. |
| `search_entities` | Fast Parallel Entity Search for people/company candidates. |
| `enrich_account` | Parallel Task API account-level fit enrichment. |
| `enrich_accounts` | Batch account enrichment that runs multiple Parallel Task jobs concurrently. |
| `find_decision_makers` | Parallel Task API professional-contact lookup with email rules. |
| `find_decision_makers_batch` | Batch contact lookup that runs multiple Parallel Task jobs concurrently. |
| `save_lead_pack` | Terminal tool that validates and renders the final lead pack. |

The shared `examples/shared/parallel_client.rb` includes small HTTP wrappers for
the Parallel Task, FindAll, and Entity Search APIs. The shared
`examples/shared/hunter_client.rb` covers Hunter Discover, Domain Search, Email
Finder, Email Verifier, enrichment, email count, and account usage endpoints for
future `find_verified_email` tools. The shared
`examples/shared/apollo_client.rb` covers Apollo People API Search, Organization
Search, people/company enrichment, bulk enrichment, webhook polling, and API
usage/rate-limit stats for future named decision-maker discovery tools.

## Prompting and skill strategy

The workflow has three layers of instructions:

1. orchestrator `TurnKit::Agent` (`orchestrator: true`) preamble: autonomous task execution,
   tool-use discipline, and stopping criteria.
2. Inline workflow instructions in `bay_alarm_lead_researcher.rb`: Bay Alarm
   context, GPT-5.5 medium-thinking role, and critical no-fabrication rules.
3. `skills/bay_alarm_outbound_research.md`: the detailed operating procedure for
   vertical research, account scoring, contact rules, citations, and final output.

The skill tells the model to research first, then discover companies, then enrich
only promising accounts, then search contacts, then save exactly once.

Because Apollo People Search performs best with structured company identifiers,
the workflow now treats account domains as first-class data. Company discovery
and enrichment should preserve the official website plus a normalized bare domain
without protocol, path, `www.`, or `@`. Contact research should carry that domain
forward so future Apollo-backed tools can search with `q_organization_domains_list[]`
and then enrich only the top role-relevant people.

For latency, the skill prefers `enrich_accounts` and
`find_decision_makers_batch`. TurnKit dispatches separate tool calls serially, so
the batch tools run the Parallel work concurrently inside one tool call. The
`find_companies` tool also compacts the raw FindAll response before returning it
to the model; full FindAll results can be large enough to slow down later model
steps.

## Email policy

This example intentionally does not integrate Hunter, Apollo, People Data Labs,
NeverBounce, or another verification provider. Because of that, the prompt and
final save validation enforce conservative behavior:

- named decision-makers are preferred over generic inboxes;
- owner/CEO/president, operations leaders, facilities/security/yard/fleet
  managers, and controller/CFO roles are prioritized as likely physical-security
  buyers or influencers;
- direct public work emails and direct work phones are preferred when available;
- generic emails like `info@`, `contact@`, `admin@`, and department inboxes are
  fallback routing contacts, not substitutes for named-buyer research;
- public business email with source URL is acceptable;
- verified email is acceptable only if a real provider/tool says verified;
- guessed or pattern-inferred emails are not acceptable;
- missing emails should be marked `unavailable` or `needs_verification`;
- personal/home emails should not be included.

For production, add a dedicated `find_verified_email`, `verify_email`, or contact
data-provider tool. Keep GPT-5.5 as the arbiter of provenance and purchase-role
fit, not the source of truth for exact email addresses.

## Parallel processor choices

Recommended defaults:

- Vertical research: `pro-fast` for interactive deep-enough research.
- Account enrichment: `core-fast` for structured fit signals up to roughly 10
  fields.
- FindAll generator: `core` for better account discovery; `preview` for tests.

Useful environment knobs:

```sh
PARALLEL_DEEP_PROCESSOR=pro-fast
PARALLEL_TASK_PROCESSOR=core-fast
PARALLEL_FINDALL_GENERATOR=core
PARALLEL_FINDALL_POLL_SECONDS=240
PARALLEL_READ_TIMEOUT=180
```

## Implementation notes

- The final lead pack is rendered by Ruby, not free-form model prose.
- The terminal save tool validates required account fields, source presence, score
  bounds, and email status consistency.
- `FindAll` is asynchronous, so `find_companies` creates the run, polls until it
  completes or times out, then fetches results.
- The example keeps all state in memory and prints the lead pack to stdout.
- This is an example, not legal advice. Production cold outreach should include
  CAN-SPAM-compliant sender identity, opt-out handling, suppression lists, and
  CRM audit trails.
