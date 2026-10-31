# Bitter lesson: doubt-driven-review

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-29 design (George).
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Where it runs | strong | Protocol from the harness: only a context that can spawn gets a fresh reviewer. Expires if nested subagents become routine. | 2027-04-29 | | |
| 1. Claim | strong | Naming the claim first separates a decision from a vibe. A smarter model may do it silently; the two lines are cheap. Could become a learned example. | 2027-04-29 | | |
| 2. Extract the artifact and the contract | invariant | Feedback signal: a reviewer handed the claim agrees with it, and one with no contract can only judge taste. The worked example (a seam beside the plan's seam) was exactly this. Holds for any model. | | | |
| 3. Route to the reviewer and lens | strong | Routing table over the reviewer subagents. Could be generated from agent frontmatter or learned from routing history. | 2027-04-29 | | |
| Paste this at the top of the brief | invariant | The framing decides the answer: an issues-only prompt is what makes the pass adversarial, whatever the model. | | | |
| 4. Second model for one-way doors | strong | Model diversity catches shared blind spots. More compute makes it cheaper, not obsolete. The fallback order is a rate-limit rule and changes with quotas. | 2027-04-29 | | |
| An external CLI | invariant | Safety rule: an artifact may carry instructions, so an outside agent runs read-only, from stdin, and only on the user's yes for that exact command. | | | |
| 5. Reconcile | invariant | The lead owns the verdict and re-reads the artifact. Deferring to a reviewer that lacks context is the failure, for any model. | | | |
| 6. Stop | strong | The three-cycle bound and escalation are protocol. A smarter loop may judge convergence itself; until an ablation shows that, keep the bound. | 2027-04-29 | | |
