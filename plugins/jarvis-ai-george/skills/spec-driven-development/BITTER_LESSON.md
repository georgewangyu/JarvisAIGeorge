# Bitter lesson: spec-driven-development

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-27 design.
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Pick the mode | strong | Brief by default, full when earned. Sizing the artifact to the risk is protocol; a smarter model may size it on its own, but the one-way-door triggers are a cheap alignment check. | 2027-04-27 | | |
| The done check must be able to fail | invariant | Feedback signal: a check that cannot fail cannot tell anyone the work is done. Holds for any model. | | | |
| Proof wanted names the evidence | invariant | Feedback signal: the named evidence is what the human verifies. | | | |
| Out of scope is never blank | invariant | Real invariant: unstated non-goals are the main source of misalignment. | | | |
| Synthesize, do not re-interview | strong | Protocol: the human's time goes only to what is still missing. Could become a learned example. | 2027-04-27 | | |
| Phase 0: Scope check | strong | Splitting bundled capabilities keeps each spec reviewable. Could become a hard check on capability count. | 2027-04-27 | | |
| Sections | strong | Full template is shared output protocol with the project's design-doc format and the reviewer. | 2027-04-27 | | |
| 4. Boundaries | invariant | Rules of the game: always / ask first / never is where irreversible actions are gated. | | | |
| 7. Test seams | invariant | Feedback signal: the seam is where the done check runs. Existing and highest seams keep it trustworthy. | | | |
| 8. Out of scope | invariant | Same invariant as the brief field: never blank. | | | |
| Design contract for multi-PR work | invariant | Real invariant across a series: without named invariants and per-PR ownership, later PRs drift from the design. | | | |
| Review gate | strong | Normal plus blind eval before building is protocol. More compute makes it cheaper, not obsolete. Could become a hard gate on full specs. | 2027-04-27 | | |
| Keep it alive | strong | Protocol: spec before code on a change of course, PRs link their section. Could become a hard check on PR descriptions. | 2027-04-27 | | |
