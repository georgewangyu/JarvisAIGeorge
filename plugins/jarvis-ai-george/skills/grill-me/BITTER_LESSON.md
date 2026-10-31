# Bitter lesson: grill-me

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-26 design.
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Pick the mode | strong | Protocol split (intent vs design). A smarter model may pick the right questions without naming a mode. | 2027-04-26 | | |
| Step 2: Facts are your job | invariant | Rule of the game: the human's time goes only to decisions. Holds for any model. | | | |
| Step 3: Ask in rounds | strong | Interaction protocol (frontier, at most 4, recommended answer first). Could become a tool-enforced shape. | 2027-04-26 | | |
| Step 4: Want vs should want | soft | Coaching on reading answers. A strong model probes buzzwords on its own. | 2027-01-26 | An ablation shows the same probing of buzzword answers without it. | |
| Step 5: Stop test | strong | Checkable stop rule. Could be learned from session outcomes. | 2027-04-26 | | |
| Step 6: Restate | strong | Output protocol shared with downstream skills. | 2027-04-26 | | |
| Out of scope is required | invariant | Real invariant: unstated non-goals are the main source of misalignment. | | | |
| Step 7: Explicit yes | invariant | Feedback signal: the only evidence the intent is shared. | | | |
| Output | strong | Protocol: persist to docs/intent, hand off to a spec. | 2027-04-26 | | |
| Non-interactive runs | strong | Team protocol, matches start-playbook rule 2. Could become a hard check on worker reports. | 2027-04-26 | | |
