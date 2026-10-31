# Bitter lesson: start-playbook

Full analysis for the inline `[bl: ...]` tags in `SKILL.md`. Read only when
evaluating the skill (cleanup, `report`, `ablate`). One row per tagged item,
keyed by the item's first words. 
Tags: invariant = rules of the game, always follow. strong = follow it, should
become a hard check or learned example. soft = guidance for weaker models,
candidate to expire. Checker: `skills/principles-bitter-lesson/scripts/bitter_lesson.py`.

| Item | Tag | Why | Review | Delete when | Ablation |
|---|---|---|---|---|---|
| Skill Discovery | strong | Routing tree is team protocol. Could be generated from skill frontmatter or learned from routing history. | 2027-04-26 | | |
| 1. Surface Assumptions | strong | Protocol. The local override narrows it: proceed on reversible work, stop on prod. | 2027-04-26 | | |
| 2. Manage Confusion Actively | strong | Rewritten from upstream "STOP and wait": facts are the agent's job, reversible calls are decided and logged, one-way doors are asked with a recommendation, never idle (Matt Pocock grilling, two-way vs one-way doors, pstack never-block). A protocol; could become a hard gate on one-way-door actions. | 2027-04-26 | | |
| 3. Push Back When Warranted | soft | Coaching against sycophancy. | 2027-01-26 | An ablation shows no change in pushback on bad approaches without it. | |
| 4. Enforce Simplicity | soft | Prose coaching. The durable form is size caps and reviewer gates. | 2027-01-26 | A diff size cap or a simplicity reviewer gates every change. | |
| 5. Maintain Scope Discipline | strong | Could become a hard diff-scope check against the task. | 2027-04-26 | | |
| 6. Verify, Don't Assume | invariant | Feedback signal. Includes the Definition of Done in `references/definition-of-done.md`. | | | |
| Failure Modes to Avoid | soft | Restates behaviors 1 to 5 as a list. | 2027-01-26 | Behaviors 1 to 5 are deleted or gated, or an ablation shows no change. | |
| 2. Skills are workflows | soft | Rigid step order makes up for weak judgment on which steps matter. | 2027-01-26 | Models pick steps by judgment and an ablation shows no skipped verification. | |
| Lifecycle Sequence | soft | Fixed sequence is a heuristic. | 2027-01-26 | Routing picks the right skills without a fixed sequence. | |
| Quick Reference | soft | Hand-kept copy of skill descriptions. | 2027-01-26 | The table is generated from skill frontmatter. | |
| Local overrides | strong | Local protocol on top of upstream. | 2027-04-26 | | |
| Verify: the checks that run | invariant | Feedback signal: the change's own CI is the build gate. | | | |
| Surface assumptions: on reversible | strong | Protocol. Could become a hard gate on production actions. | 2027-04-26 | | |
| Comments: comment cleanup only | strong | Protocol. A diff-scoped comment reviewer can enforce it. | 2027-04-26 | | |
| Don't know what you want yet | strong | Routing pointer to grill-me. Could be learned from routing history. | 2027-04-26 | | |
| Have a rough idea | strong | Routing pointer to brainstorm. Could be learned from routing history. | 2027-04-26 | | |
| Direction settled | strong | Routing pointer to spec-driven-development. Could be learned from routing history. | 2027-04-27 | | |
| Have a spec, and it needs | strong | Routing pointer to planning-and-task-breakdown. Could be learned from routing history. | 2027-04-29 | | |
| Ready to implement a slice | strong | Routing pointer to incremental-implementation. Could be learned from routing history. | 2027-04-29 | | |
| About to use an API | strong | Routing pointer to source-driven-development. Could be learned from routing history. | 2027-04-29 | | |
| About to let a non-trivial decision | strong | Routing pointer to doubt-driven-review. Could be learned from routing history. | 2027-04-29 | | |
| Building or changing UI | strong | Routing pointer to frontend-ui-engineering. Could be learned from routing history. | 2027-04-29 | | |
| Writing or fixing tests | strong | Routing pointer to test-driven-development. Could be learned from routing history. | 2027-04-30 | | |
| Checking UI in a real browser | strong | Routing pointer to browser-testing. Could be learned from routing history. | 2027-04-30 | | |
| Something broke, or an alarm | strong | Routing pointer to debugging-and-error-recovery. Could be learned from routing history. | 2027-04-30 | | |
| Reviewing a change, or got review comments | strong | Routing pointer to code-review-and-quality and the three Review skills. Could be learned from routing history. | 2027-04-30 | | |
| Committing, branching, pushing | strong | Routing pointer to git-workflow-and-versioning. Could be learned from routing history. | 2027-04-30 | | |
| Setting up or changing CI | strong | Routing pointer to ci-cd-and-automation. Could be learned from routing history. | 2027-04-30 | | |
| Retiring, renaming or replacing | strong | Routing pointer to deprecation-and-migration. Could be learned from routing history. | 2027-04-30 | | |
| Recording a decision or writing docs | strong | Routing pointer to documentation-and-adrs. Could be learned from routing history. | 2027-04-30 | | |
| Adding logs, metrics or alerts | strong | Routing pointer to observability-and-instrumentation. Could be learned from routing history. | 2027-04-30 | | |
| Deploying or launching | strong | Routing pointer to shipping-and-launch. Could be learned from routing history. | 2027-04-30 | | |
| Need the quality bar | strong | Routing pointer to quality-constraints and mistake-miner. Could be learned from routing history. | 2027-04-29 | | |
| Designing an API | strong | Routing pointer to api-and-interface-design. Could be learned from routing history. | 2027-04-29 | | |
| Loading context | strong | Routing pointer to context-engineering. Could be learned from routing history. | 2027-04-29 | | |
| Evaluating a claim | strong | Routing pointer to the principles group. Could be learned from routing history. | 2027-04-26 | | |
