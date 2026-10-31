---
name: doubt-driven-review
description: "Cross-examine a non-trivial decision before it stands. A thin router: name the claim, hand only the artifact and its contract to the right fresh-context reviewer (code, design doc, change plan, comments, or a general reviewer) with the right lens, add a second model for one-way doors, then reconcile every finding and stop after three cycles. In-flight, not the final review. Use when about to commit non-trivial code, claim something is safe, add a seam to a multi-PR series, take a one-way door, or when the user says doubt, challenge this, stress test, find blind spots, or tear this apart."
---

# Doubt

A confident answer is not a correct one. Before a non-trivial decision stands, give it to a fresh reviewer whose job is to disprove it. This skill picks the reviewer and the lens. The reviewer does the review.

## When to use

A decision is non-trivial when at least one is true:

- It adds or changes branching logic, or crosses a module, service or package boundary.
- It claims a property the compiler cannot check (thread safety, idempotence, ordering, an invariant).
- It adds a seam, callback or mode that later PRs in a series will rely on.
- It is a one-way door: data format, public API, delete, migration, production config, another team's system.
- You are about to say "this is safe", "this scales", or "this matches the plan".

Not for: renames, formatting, file moves, a clear user instruction, one-line fixes with obvious correctness, reading or summarizing code, or when the user asked for speed.

Doubt is in-flight, per decision, while changing course is cheap. A code review gives the final verdict on a finished PR. Use both.

## Where it runs [bl: strong]

From the main session or an orchestrator that can spawn subagents. A reviewer never runs doubt on itself. A subagent that cannot spawn says so in its report and leaves the doubt pass to its parent. A self-check with a mental reset is a degraded fallback only: label it "degraded, not fresh context".

## 1. Claim [bl: strong]

Write the decision in two lines and keep it to yourself:

```
CLAIM: the seeder needs its own restart hook because one process cannot halt after the seed is stored.
WHY IT MATTERS: the next PR will build on whatever fault path this one ships.
```

If you cannot write it that short, you have a vibe, not a decision. Name it first.

## 2. Extract the artifact and the contract [bl: invariant]

The reviewer gets the artifact and the contract. It never gets the claim or your reasoning, which biases it toward agreeing.

- **Artifact:** the diff or the function, not the whole file. A decision goes in three to five sentences. Over about 400 changed lines, split it first.
- **Contract:** what the artifact must satisfy, quoted from its source. The spec's done check and out of scope. The plan's design contract (invariants and the ownership table, required for any multi-PR series). The project's constraints or detected gates. The API doc for an interface.

A missing contract is the first finding. Without one the reviewer can only judge taste.

## 3. Route to the reviewer and lens [bl: strong]

| Artifact | Reviewer | Mode |
|---|---|---|
| PR diff or local commit | the `reviewer` agent with `code-review-and-quality/references/cr-review-checklist.md` (coding extension) | normal (description plus plan) and, for a one-way door, blind (patch only) |
| Spec, design doc, plan | the `reviewer` agent with [`references/design-review-checklist.md`](references/design-review-checklist.md) | normal, plus blind (doc only) for a full spec |
| Change plan or runbook for production | a change reviewer subagent | rollback, testing evidence, phasing |
| Comments a diff adds or changes | a comment judge subagent | keep only comments that explain a non-obvious why |
| A claim or a number, no artifact | `principles-scientific-method` or `principles-first-principles` | prediction or Fermi bound |
| Anything else | a general-purpose subagent | the adversarial prompt below |

Run `reviewer` (the read-only agent in this plugin, in Claude Code `jarvis-ai-george:reviewer`) with only the artifact, the contract and the checklist. In a tool without agents, start a fresh session that loads `role-reviewer` and give it the same three things.

Pick one or two lenses and name each with a one-line reason, for example "operations: the change reorders a deploy". Every lens beyond two dilutes the brief.

| Lens | Use when |
|---|---|
| Correctness | always on |
| Plan conformance | a multi-PR series: does it add a seam beside the plan's seam, or pull a later PR's scope in? |
| Security | auth, credentials, sensitive data, a new endpoint, a trust boundary |
| Operations | deploy order, alarms, rollback, blast radius |
| Design | a new UI flow, a new state owner, focus or keyboard handling (`frontend-ui-engineering`) |
| Scope | many requirements, stretch goals, scope that does not match the goal |
| Premise | a one-way door, a new abstraction, an unchallenged alternatives section |

Paste this at the top of the brief. It overrides any reviewer's balanced-verdict default. [bl: invariant]

```
Adversarial review. Find what is wrong with this artifact under the contract.
Assume the author is overconfident. Look for unstated assumptions, unhandled
edges, hidden coupling or shared state, contract violations, broken house
conventions, and failure under unexpected input. Do not validate or summarize.
Report issues, or say plainly that you found none after a thorough look.
ARTIFACT: <artifact>
CONTRACT: <contract>
LENS: <lens and reason>
```

Ask each reviewer to write its findings to a file you name, so a re-run can diff against it.

## 4. Second model for one-way doors [bl: strong]

A reviewer on the same model shares the author's blind spots. For a one-way door, or a seam a series will build on, run the same brief on two different models at once.

- Prefer two models your harness offers (the subagent model field). If one is rate-limited, rerun on the next strong model at once and say which model ran.
- An external CLI (another vendor's agent) needs the user's yes for that exact command every time, a read-only sandbox, and the prompt piped through stdin from a file, never interpolated into a shell argument. A failed or missing CLI is reported, never silently skipped. [bl: invariant]
- Two-way doors get one model. Say "single model" in the output so the skip is visible. Non-interactive runs never call an external CLI and say so.

## 5. Reconcile [bl: invariant]

The findings are data, not a verdict. You are still the lead. Re-read the artifact text before you classify each finding. Agreeing with the reviewer without re-reading is the same failure as ignoring it.

Classify in this order. The first class that fits wins.

1. **Contract misread.** The contract was unclear or incomplete. Fix the contract, then re-run.
2. **Act on.** A real issue under the contract. Change the artifact and loop.
3. **Consider.** Real, but fixing may cost more than accepting. Write the trade-off down for the user.
4. **Dismissed.** Wrong under context the reviewer lacked, with a one-line reason. Ask whether adding that context to the contract would have prevented it.

Filters for the lead:

- A finding raised by both models, or by both the normal and blind pass, is the strongest signal. Weight a lone finding, do not drop it.
- "What if X is null" counts only if a caller can pass null. Trace the call site.
- "I would have done it differently" with no concrete failure is dismissed.
- Security and correctness findings get extra scrutiny before you dismiss them, even from one model.
- No performative agreement when you fold findings back. Restate the fix, or push back with the reason.

## 6. Stop [bl: strong]

Stop when the next pass returns only trivial or already-handled findings, after three cycles, or when the user says ship it. Three cycles that still raise substantive findings are information about the artifact. Escalate to the user. Do not grind a fourth cycle alone and do not lift the bound. An artifact too big for three cycles goes back to step 2 and gets split.

## Output

```
Claim: <one line>
Reviewers: <reviewer, lens, model> per reviewer (or "single model")
Act on: <finding, who raised it, the change made>
Consider: <finding, the trade-off>
Dismissed: <finding, the reason>
Agreement: <where reviewers agreed or split>
Stopped: <trivial findings | 3 cycles, escalated | user said ship>
```

## Non-interactive runs

Workers and loops run the same steps with the harness's own models. A one-way door that still has Act on findings after three cycles stops and goes to a human. It is never shipped on a log line. This matches rule 2 of `start-playbook`.

## Worked example: a seam beside the plan's seam

A four-PR series had one written invariant: every fault goes through one helper with a swappable strategy, and each PR swaps the strategy, never rewrites it. On PR 3, revision 4, a fresh worker added a separate restart hook to the seeder so a unit could restart after its seed was stored. The reviewers got the worker's reasoning without the plan and accepted it. A teammate caught it in review, and the hook was dropped. The seeder now reports through the helper.

The doubt pass that should have run:

- **Claim** (kept back): "the restart hook is needed because one process cannot halt after the seed store."
- **Artifact:** the revision 4 seeder diff. **Contract:** the plan's invariant, quoted.
- **Route:** the code reviewer with the plan conformance lens, plus a blind pass. The hook is a seam PR 4 would build on, so two models review.
- **Expected Act on:** "a new seam beside the plan's seam; isolation is PR 4's scope". Both passes can see it, since the blind pass finds a second fault path in the code alone.

The miss was step 2. The reviewers got the claim and not the contract.

## Red flags

- The reviewer got the claim, your reasoning, or no contract.
- A prompt that asks "is this good?" instead of "find what is wrong".
- Doubt on a rename or a one-liner.
- Findings taken as the verdict without re-reading the artifact.
- Doubt theater: two or more cycles with substantive findings and zero Act on.
- A fourth cycle without asking, or the same unchanged artifact re-sent.
- A one-way door reviewed by one model with no "single model" note.
- An external CLI run without the user's yes for that exact command.

## Related

- `spec-driven-development` and `planning-and-task-breakdown` review gates use the same reviewers. `incremental-implementation` reviews every slice revision. Doubt is for a decision inside a slice, before it is written up.
- `quality-constraints` guards the bar on every diff.

## Sources

- [addyosmani/agent-skills `doubt-driven-development`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/doubt-driven-development/SKILL.md) at `aeac41d`, MIT (see `THIRD_PARTY_LICENSE-agent-skills`): the non-trivial test, claim / extract / doubt / reconcile / stop, never pass the claim, the adversarial prompt overriding a persona's default, cross-model with a read-only sandbox and stdin, reconcile precedence, the three-cycle bound, doubt theater.
- [cursor/plugins pstack `interrogate`](https://github.com/cursor/plugins/blob/10d7b8a647caedfca8143ca8335d9e063c027227/pstack/skills/interrogate/SKILL.md) and its `references/lead-judgment.md` at `10d7b8a`, MIT (see `THIRD_PARTY_LICENSE-pstack`): diversity from models rather than personas, one reviewer per model in parallel, the lead as judge, the Act on / Consider / Dismissed buckets, the agreement map, hypothetical vs actual, "I would have done it differently".
- [EveryInc/compound-engineering-plugin `ce-doc-review`](https://github.com/EveryInc/compound-engineering-plugin/blob/6500180a95ee132d612c58ceb6cb2fffe40766e6/skills/ce-doc-review/SKILL.md) and `references/persona-selection.md` at `6500180`, MIT (see `THIRD_PARTY_LICENSE-compound-engineering-plugin`): conditional lenses chosen by signals and announced with a reason.
- [obra/superpowers `receiving-code-review`](https://github.com/obra/superpowers/blob/2ce8aa15d05bd57213e6f746f953aafb7ded7a8b/skills/receiving-code-review/SKILL.md) at `2ce8aa1`, MIT (see `THIRD_PARTY_LICENSE-superpowers`): verify before you implement, no performative agreement.
- Rewritten here, not copied. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
