# Bitter lesson: documentation-and-adrs

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-30 design.
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| 1. Match the existing convention first | strong | Protocol; a check could detect a second ADR or docs scheme. | 2027-04-30 | | |
| 2. One doc, one mode | strong | Structure rule from Diataxis; could be learned from reviewed docs. | 2027-04-30 | | |
| 3. ADRs: when, and how short | strong | The three-condition bar keeps ADRs rare and useful; the template is a team format. | 2027-04-30 | | |
| 4. A glossary that ages well | soft | Format guidance a strong model can infer from an existing glossary. | 2027-01-30 | An ablation shows consistent terms without it. | |
| 5. Write it so it lasts | strong | Docs with the behavior and claims true at the commit are checkable rules. | 2027-04-30 | | |
| 6. Keep a learning only if the code cannot tell it | soft | Judgment heuristic for note-taking; expires with better recall. | 2027-01-30 | An ablation shows no growth in redundant notes without it. | |
| 7. Prose review | soft | Writing coaching; the user's style rules cover most of it. | 2027-01-30 | An ablation shows no change in doc quality without it. | |
