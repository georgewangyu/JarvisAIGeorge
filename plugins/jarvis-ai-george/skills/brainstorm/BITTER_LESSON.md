# Bitter lesson: brainstorm

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-26 design.
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Step 0: Ground first | invariant | Rule of the game: the human's time goes only to decisions, and options not grounded in the real system are guesses. Holds for any model. | | | |
| Step 1: Premise challenge | strong | Protocol (premises confirmed before options). A smarter model may challenge framing on its own, but the confirmation is a cheap alignment check. | 2027-04-26 | | |
| Step 2: Diverge | strong | Axis spread and lenses fight mode collapse on the first idea. Could become a learned example or a hard check on axis coverage. | 2027-04-26 | | |
| Step 3: Converge | strong | Option format (pros, cons, cost check, assumption, door) is a shared protocol. Could be tool-enforced. | 2027-04-26 | | |
| Mark one-way doors | invariant | Irreversible choices belong to the user. A rule of the game, not a model weakness. | | | |
| Step 4: Pick or bake off | strong | Bakeoff depth (2 to 3 throwaway versions, criteria fixed before building) is protocol. More compute makes it cheaper, not obsolete. | 2027-04-26 | | |
| Step 5: Decision note | strong | Output protocol shared with the save step and the spec step. | 2027-04-26 | | |
| Every assumption has a test | invariant | Feedback signal: an assumption with a test is the only way the decision gets checked later. | | | |
| Not Doing is required | invariant | Real invariant: unstated non-goals are the main source of misalignment. | | | |
| Non-interactive runs | strong | Team protocol, matches start-playbook rule 2. Could become a hard check on worker reports. | 2027-04-26 | | |
