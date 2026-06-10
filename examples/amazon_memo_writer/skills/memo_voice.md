---
name: Memo Voice
description: Output-facing voice, clarity, and forbidden-word rules for event organizer and photographer audiences.
---

Audit only observable rendered Markdown. Treat these as output-facing rules, not
private drafting instructions.

## Audience

Write for non-technical event organizers and photographers. They care about
reducing registration friction, helping attendees find photos, saving staff
time, and making events easier to run. Explain technical terms in plain language
or replace them with concrete outcomes.

## Tone

Use a voice that is:

1. Professional but approachable.
2. Helpful and educational.
3. Confident but not salesy.
4. Focused on solving practical problems for event organizers and photographers.

## Words to Prefer

Prefer specific, concrete language such as:

1. save time
2. reduce manual work
3. help attendees find their photos
4. speed up check-in
5. fewer support requests
6. easier setup
7. clear next steps
8. trusted proof
9. accurate photo matching
10. faster delivery
11. less back-and-forth
12. simple workflow

## Buzzwords to Never Use

Fail buzzword_forbidden when the output uses any of these words or phrases
unless the output is quoting source text and clearly labels it as a quote:

1. Revolutionary
2. Game-changing
3. Disruptive
4. Cutting-edge
5. State-of-the-art
6. Best-in-class
7. Synergy
8. Leverage
9. Optimize
10. Innovative
11. Groundbreaking
12. Next-generation
13. World-class
14. Industry-leading
15. Unparalleled
16. Transform
17. Revolutionize
18. Reimagine
19. Seamless
20. Robust
21. Scalable
22. Enterprise-grade

Replace buzzwords with the specific thing the feature does. For example, write
"attendees can find photos by entering their bib number" instead of "a
next-generation discovery experience."

## Other Words to Avoid

Fail minimizing_or_condescending_language when the output uses these words in a
way that minimizes the reader's work or sounds condescending:

1. Simply
2. Just
3. Obviously
4. Clearly

Use direct instructions instead. For example, write "Upload the attendee list"
instead of "Simply upload the attendee list."

## Dashes

Fail no_em_dash when the output contains Unicode U+2014. Fail no_en_dash when the
output contains Unicode U+2013. Replace those characters with one of these:

1. A period and a new sentence.
2. A comma, if the sentence still reads naturally.
3. Parentheses for a short aside.
4. A "which" or "that" clause.

Do not fail ordinary hyphens used in phrases like "follow-up" or "source-grounded."

## Transition Flow

Check whether section transitions feel abrupt. If a section jumps to a new idea
without context, add one short transition sentence that explains how the next
section follows from the previous one.

## Jargon Check

Fail unexplained_jargon when technical terms appear without a plain-language
definition. Prefer reader-centered wording:

1. Write "photo matching" instead of "computer vision pipeline" unless the
   technical system matters.
2. Write "attendee list" instead of "CSV import" when the file format is not the
   point.
3. Write "connects to your registration tool" instead of naming an integration
   pattern the audience may not know.

## Claims and Statistics

Fail unsupported_claim when numerical claims, percentages, time savings,
accuracy claims, or comparisons appear without source support. Keep sourced
claims close to the citation. If a claim is directional but not measured, say it
plainly without inventing a number.

## Format Checks

1. Fail numbered_lists_only only when a rendered list item line begins with "- "
   or "* ".
2. Do not treat the "Next Steps" section as additional recommendations. It is
   required action planning.
3. Do not fail for style preferences that are not directly visible in the
   rendered Markdown.
