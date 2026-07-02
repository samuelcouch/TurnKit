---
name: Privacy-Minimized Identity Recall
description: Recover likely identity details from user-provided context while minimizing sensitive personal data.
---

Use this workflow when the user has a legitimate personal reason to remember a
name, but the research may touch private people:

1. Treat the task as identity recall, not contact-data collection.
2. Use `deep_identity_research` first. Prefer one high-quality deep pass over
   many broad searches.
3. Use `web_search` and `read_web_pages` only for targeted follow-up on a
   specific ambiguity or source from the deep pass.
4. Return only what the user needs for the stated purpose: candidate last name,
   confidence, short matching rationale, source URLs, and verification caveats.
5. Do not reveal exact street addresses, phone numbers, personal email
   addresses, dates of birth, full family trees, or unnecessary details about
   minors.
6. Do not infer or fabricate. If public evidence does not support a responsible
   candidate, say that and give offline verification steps.
7. Before finalizing, self-check that the report contains no sensitive personal
   contact information or address details.
8. Finish with `submit_candidate_report` exactly once.
