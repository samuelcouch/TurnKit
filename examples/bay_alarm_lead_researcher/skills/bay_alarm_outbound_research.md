---
name: Bay Alarm Outbound Research
description: Research one Southern California vertical, find cited business prospects, identify professional decision makers, and save a compliant outbound lead pack.
---

Use this workflow for B2B cold-sales prospecting for Bay Alarm in Southern California.

## Mission

Given one vertical and region, produce a sales-ready lead pack with:

1. A vertical research brief: why this industry buys commercial alarm, video,
   fire monitoring, access control, or related security services.
2. A ranked account list: real businesses in the requested Southern California
   geography with source-backed fit signals.
3. Decision-maker candidates: professional contacts only, tied to a source or
   marked unavailable.
4. Email status: never fabricate emails. Return only public or verified emails;
   otherwise use `null` and explain how to verify later.
5. Outreach angles: short, source-safe personalization for each account.

## Default geography

When the user says Southern California, interpret it as Los Angeles, Orange, San
Diego, Riverside, San Bernardino, Ventura, Imperial, and Santa Barbara counties
unless they narrow the geography.

## Research order

This example is quality-first, not speed-first. Unless the user explicitly asks
for a smoke test, lower cost, or faster interactive run, use the built-in high
quality Parallel defaults:

- `research_vertical`: `ultra` processor for deeper vertical context;
- `find_companies`: `pro` FindAll generator for the most thorough discovery;
- `enrich_account(s)` and `find_decision_makers(_batch)`: `pro` processor for
  multi-source account/contact verification.

Do not choose `-fast` processors in normal runs. Fast processors are for explicit
speed requests and can trade quality/freshness for latency.

1. Normalize the request into an ICP:
   - vertical and synonyms;
   - included and excluded business types;
   - target counties/cities;
   - likely buying triggers;
   - decision-maker titles;
   - disqualifiers.
2. Call `research_vertical` before generating accounts. Use it to understand the
   security risk story and decide how to score accounts. If the workflow input
   includes `cached_vertical_research`, treat vertical research as already
   completed and proceed directly to account discovery using that research.
3. Use `draft_findall_schema` or your own reasoning to create precise FindAll
   match conditions. Review and tighten them before `find_companies`.
4. Use `find_companies` for the initial account list. Start smaller when the
   user did not specify count; quality beats volume. For each candidate, preserve
   the canonical company name, primary website URL, normalized domain without
   `www.`, and relevant location to distinguish companies with similar names.
   - Call `find_companies` at most once for the main discovery pass. Do not make
     several exploratory FindAll calls. If you need broader coverage, put the
     synonyms, geography, multi-location preference, exclusions, and quality bar
     into one objective and one set of match conditions before calling it.
   - After calling `find_companies`, wait for and use its result. Do not issue a
     second `find_companies` call merely to refine wording, expand geography, or
     test a nearby synonym. Refine downstream by shortlisting/enriching the
     returned candidates.
5. Use `enrich_accounts` for the best accounts, not every weak candidate. Prefer
   one batch call over repeated `enrich_account` calls unless you only need a
   single account. During account enrichment, explicitly verify or recover the
   primary website/domain from company sources before contact research.
6. Use `find_decision_makers_batch` only after accounts appear qualified. Prefer
   one batch call over repeated `find_decision_makers` calls unless you only need
   one account. Pass the account's normalized domain whenever available for
   company-domain matching.
7. Save the final pack with `save_lead_pack`. This is the terminal tool.

Do not use `search_entities` during quality-first runs unless FindAll is
unavailable or has failed. FindAll is the preferred discovery mechanism because
it evaluates candidates against explicit match conditions and returns better
evidence for a final lead pack.

## One-pass discovery rule

The expensive discovery stage should be planned before it is executed. Never
chain multiple discovery calls as a brainstorming tactic. A good `find_companies`
call should already include:

- all relevant vertical synonyms;
- target cities/counties and excluded geographies;
- independent/regional/multi-location preference;
- disqualifiers such as national chains or irrelevant distributors;
- required evidence such as website/domain, physical storefront/yard, and local
  operating footprint;
- a match limit large enough to shortlist from, instead of a second discovery
  call.

Only call `find_companies` again if the first call returns an explicit tool/API
failure or an unusably empty result. Do not retry just because the model wants a
slightly different phrasing.

## Latency discipline

- Quality matters more than speed for this example. Keep the first pass focused,
  not shallow: find enough companies to have choice, then enrich only the best
  candidates deeply.
- Do not enrich every candidate returned by FindAll. Use the compact candidate
  evidence to shortlist first.
- Use batch tools for account and contact research. TurnKit executes tool calls
  serially, so repeated single-account calls are much slower than one batch call.
- If contact research is slow or weak, save the account with `contacts: []` and a
  next action to verify contacts in CRM, LinkedIn, or an approved email provider.

## Fit scoring

Score accounts from 0 to 100. Reward:

- physical commercial premises in Bay Alarm's likely service area;
- after-hours risk;
- valuable tools, inventory, vehicles, equipment, cash, controlled access, or
  fire/life-safety needs;
- independent or regional buying authority;
- recently opened, expanded, renovated, licensed, reviewed, or otherwise active;
- relevant decision-maker found;
- public or verified professional email found.

Penalize:

- national chains with centralized purchasing;
- businesses outside the requested geography;
- vague directory listings with no website or source evidence;
- missing or ambiguous company domain when a website should exist;
- weak connection to commercial security needs;
- consumer/private-person data.

## Contact and email rules

- Professional context only. Do not profile consumers.
- Never invent a person, title, email, LinkedIn URL, or source.
- Never infer an email pattern as fact.
- Optimize for exact named decision-makers, not generic inboxes. A useful lead
  contact is a real person with a title that plausibly owns or influences a
  physical-security purchase.
- Prioritize named contacts in this order:
  1. owner, CEO, president, dealer principal, principal, or managing partner;
  2. COO, VP operations, director of operations, general manager;
  3. facilities/property/security/yard/fleet/dispatch manager;
  4. controller, CFO, or finance leader who can approve vendor spend.
- For each named contact, look for exact professional contact info: direct work
  email, direct office phone, company profile page, LinkedIn/profile URL, and the
  source that ties the person to the company.
- If research returns a named person without an email, keep the
  person if their role is strong, set `email_status` to `needs_verification` or
  `unavailable`, and include the profile/provider source. Do not downgrade to a
  generic inbox unless no named contact exists.
- Generic emails such as `info@`, `contact@`, `admin@`, `customerservice@`, or
  department inboxes are fallback routing contacts only. Include them when useful,
  but do not treat them as a substitute for named decision-maker research.
- If an email is publicly listed, include the public source URL.
- If an external verifier/provider is not available, set `email_status` to
  `unavailable` or `needs_verification`, not `verified`.
- Do not include personal/home emails. Use business emails only.
- Prefer owner, president, general manager, operations manager, facilities
  manager, property manager, controller, or office manager depending on vertical.

## Citation rules

- Every account should have at least one source URL.
- Every strong personalization claim should be supported by a source URL.
- If a claim is only a vertical-level hypothesis, say so as a hypothesis.
- Keep source URLs visible in the saved pack.

## Output quality bar

The saved lead pack should be useful to a salesperson tomorrow morning:

- concise vertical brief;
- ranked lead cards;
- clear next action for each lead;
- no unsupported claims;
- no fabricated emails;
- no irrelevant directories unless they establish existence/location.
