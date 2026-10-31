# Design review checklist

Hand this file and the doc (nothing else) to the `reviewer` agent. Its job is to find the concerns, gaps and risks the author missed, not to approve the design. A doc that reads well but omits its failure modes, or never weighs the obvious alternative, fails.

## Process

1. **Read the whole doc**, not just the summary. Extract the problem statement, the proposed solution and architecture, the key decisions, and any data, API or config changes.
2. **Read the comments** if the doc has any. Note open questions, pushback and the author's answers. Do not re-raise a concern a comment already settles.
3. **Critique each major decision** on five axes: correctness (does it solve the stated problem?), alternatives (what else exists, and why not that?), trade-offs, gaps (what is missing or unclear?), risks (what breaks?).
4. **Compare alternatives** for each significant decision in a small table:

   | Aspect | Option A | Option B | Better |
   |---|---|---|---|
   | Performance | | | |
   | Complexity | | | |

## Areas to cover

- **Architecture:** fits the problem? A simpler shape? Scaling limits? Failure modes?
- **APIs and interfaces:** hard to misuse? Backward compatible? Error cases defined?
- **Data:** fits the access pattern? Edge cases? Serialization and versioning?
- **Operations:** monitoring, rollback, failure detection and recovery.
- **Migration:** the path, its risks, how long both versions coexist.
- **Multi-PR plans:** is there a design contract (series invariants plus a per-PR ownership table naming each seam)? Could a later PR's brief quote it verbatim?

## Severity

- **Critical:** breaks correctness, safety or availability, or invalidates the approach.
- **Moderate:** should be fixed but does not block the design.
- **Gap:** something the doc should cover and does not (say which section it belongs in).

## Every concern carries

- **Location:** section, step or figure.
- **Quote:** the exact text.
- **Concern:** what is wrong and why it matters, quantified where possible.
- **Recommendation:** what to add or change.

Pair every problem with a fix. Acknowledge real strengths. Avoid absolute claims you cannot back.

## Findings file

Write to the path the caller names (default `<doc-slug>-review.md`). Final message: a one-line verdict plus the path.

```markdown
# <Doc title>: review
Source: <link>  Date: YYYY-MM-DD
## Summary            what it proposes, overall verdict in 2-3 sentences
## Critical concerns  Location / Quote / Concern / Recommendation per item
## Moderate concerns
## Gaps
## Alternatives       comparison tables
## Recommendations
```
