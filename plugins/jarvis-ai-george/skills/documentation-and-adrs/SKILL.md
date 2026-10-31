---
name: documentation-and-adrs
description: "Record the why so the next human or agent does not re-decide it. Match the repo's existing doc conventions first, pick one mode per doc (tutorial, how-to, reference, explanation), write an ADR only when a decision is hard to reverse, surprising without context and a real trade-off (short template included), keep a glossary of project terms, comment the why and never the what, update docs in the same change as the behavior, and keep only learnings the code cannot already tell you. Use when making or recording an architecture decision, changing a public API or user-facing behavior, writing a README, design note, runbook or changelog, resolving a naming argument, or when the same question keeps coming up."
---

# Documentation and ADRs

Code shows what was built. Docs carry why it was built this way, what was rejected, and which constraints are invisible in the code. That context is what stops the next person, or the next agent, from "fixing" a deliberate choice.

Standing writing rules from your user or organization (style guide, where docs live, doc tooling) win over this skill.

## When to use

- A decision that would be expensive to reverse, or that a reader would question.
- A public API, CLI, config key or user-facing behavior changes.
- A README, design note, runbook or changelog entry is due.
- People keep using different words for the same thing.
- You find yourself explaining the same thing twice.

**Not for**: obvious code, comments that restate the code, throwaway prototypes.

## 1. Match the existing convention first [bl: strong]

Before writing, look for what the repo already does: an ADR folder and its numbering, a docs tree, a glossary, a changelog format, agent rules files. Match location, file type, numbering and headings. If two conventions conflict, say so; do not add a third. Use the defaults below only when nothing exists, and create files lazily, when the first entry is ready.

## 2. One doc, one mode [bl: strong]

| Mode | Serves | Rule |
|---|---|---|
| Tutorial | Learning by doing | Every step shows a visible result. |
| How-to | A goal someone has | Steps only, no background. Name it by the task. |
| Reference | Lookup | Facts, options, limits, errors. Dry and complete. Generate from code where possible. |
| Explanation | Understanding why | Context, constraints, trade-offs. Opinion allowed here only. |

Split a doc that mixes modes and link the parts.

## 3. ADRs: when, and how short [bl: strong]

Write an ADR only when **all three** hold:

1. **Hard to reverse**: changing your mind later costs real time.
2. **Surprising without context**: a reader will ask "why on earth did they do it this way?"
3. **A real trade-off**: there were genuine alternatives.

Typical cases: architectural shape, integration patterns between components, technology with lock-in, boundary and ownership decisions, deliberate deviations from the obvious path, constraints not visible in the code, non-obvious rejections.

Default location `docs/adr/NNNN-slug.md`, next number in sequence. The template:

```markdown
# NNNN. Short title of the decision

Status: accepted (proposed | accepted | superseded by NNNN)
Date: YYYY-MM-DD

Context, decision and why, in one to three sentences.

## Considered options   (only if the rejections are worth remembering)
## Consequences         (only if downstream effects are not obvious)
```

- **Never delete an ADR.** A changed decision gets a new ADR that supersedes the old one, and the old one's status points to it.
- Link the ADR from the code it explains, at the spot a reader would be confused.

## 4. A glossary that ages well [bl: soft]

Keep `GLOSSARY.md` (one per bounded area if the repo has several) for terms specific to this project, not general programming words:

```markdown
**Order**: A customer's request to buy one or more items.
_Avoid_: purchase, transaction
```

Be opinionated: one name per concept, the losers listed under _Avoid_. Update it the moment a term is settled, not at the end. No implementation detail. Use the glossary term everywhere: docs, code names, commit messages.

## 5. Write it so it lasts [bl: strong]

- **Comment the why, never the what.** A gotcha, a constraint, a link to the ADR. No commented-out code; git has it. No TODO you could just do.
- **Docs change with the behavior, in the same change.** A PR that changes behavior and leaves the README wrong is not done.
- **Write real names**: the actual file, flag, command or symbol, linked on first mention and pinned to a commit when it documents a specific state.
- **Every count or claim is true at the commit that lands it.** Include the command that regenerates a generated section.
- **Never clobber a changelog.** Add entries; polish wording only.
- **Every doc is reachable** from the README or the agent rules file.

## 6. Keep a learning only if the code cannot tell it [bl: soft]

After solving a non-obvious problem, ask: if this note vanished, would someone reading the final code and tests repeat the mistake or redo the investigation? If yes, write it down (a short note in the docs tree, or a line in the agent rules file). If the code, tests or an existing doc already make it obvious, write nothing. Update a note that became wrong instead of adding a second one.

## 7. Prose review [bl: soft]

Before you finish, re-read for the reader:

- Mark what must survive an edit: names, numbers and units, commands, paths, links, conditions, caveats.
- Cut filler, stock openers and repeated summaries. Short everyday words. One thought per sentence.
- Compare with the source: no lost qualifier, no invented guarantee, every command still works.

## Red flags

- A significant decision with no written rationale, or an ADR for something trivial.
- A new docs scheme next to an existing one.
- A behavior change with a stale README, API doc or runbook.
- One concept with three names across the docs.
- Comments that restate the code, commented-out code, old TODOs.
- An ADR edited in place after its decision changed.

## Verification

- [ ] Existing conventions found and matched (location, numbering, headings).
- [ ] Each ADR meets all three conditions and is linked from the code it explains.
- [ ] Docs, API reference and changelog updated in the same change as the behavior.
- [ ] Glossary terms used consistently.
- [ ] Every claim, count and command checked at this commit.

## Sources

- [addyosmani/agent-skills `documentation-and-adrs`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/documentation-and-adrs/SKILL.md) (MIT, see `THIRD_PARTY_LICENSE-agent-skills`): document the why, match existing conventions, ADR lifecycle, comment the why, prose review.
- [mattpocock/skills](https://github.com/mattpocock/skills) `grill-with-docs` and `domain-modeling` (see `THIRD_PARTY_LICENSE-mattpocock-skills`): the three ADR conditions, the short ADR format, the glossary format with _Avoid_, lazy file creation.
- [pstack](https://github.com/cursor/plugins/tree/main/pstack) `technical-writing` (cited, see `THIRD_PARTY_LICENSE-pstack`): one mode per doc, real names, claims true at the commit.
- [garrytan/gstack](https://github.com/garrytan/gstack) `document-release` and `document-generate` (see `THIRD_PARTY_LICENSE-gstack`): docs updated with the release, never clobber the changelog, every doc reachable, reference first.
- [EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin) `ce-compound` (see `THIRD_PARTY_LICENSE-compound-engineering-plugin`): the counterfactual bar for keeping a learning.
- [anthropics/skills](https://github.com/anthropics/skills) `doc-coauthoring` (see `THIRD_PARTY_LICENSE-anthropic-skills`): compared; its co-writing loop is not adopted.
- Rewritten here, not copied. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
