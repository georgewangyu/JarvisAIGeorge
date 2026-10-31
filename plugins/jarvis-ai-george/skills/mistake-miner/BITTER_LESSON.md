# Bitter lesson: mistake-miner

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. Verdicts from the 2026-10-29 design.
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Trigger 1: capture hook | strong | A cheap, deterministic sensor on the human's corrections. More compute does not replace a signal it never sees. The phrase list is a heuristic a learned classifier could replace. | 2027-04-29 | | |
| Trigger 2: daily harvest | strong | Collecting signals from evals, reviews, CI runs and agent rules is protocol. The class guess is a judgment a stronger model makes better, but the append-only buffer stays. | 2027-04-29 | | |
| Trigger 3: weekly cluster | strong | Batching for human pattern review (the buffer). A chief-of-staff agent may cluster continuously one day; the human decision column stays. | 2027-04-29 | | |
| After the human decides | invariant | Rules of the game: the miner never changes code or agent rules, a human approves each rule, and a rule counts only after its check fails on a real past mistake. | | | |
