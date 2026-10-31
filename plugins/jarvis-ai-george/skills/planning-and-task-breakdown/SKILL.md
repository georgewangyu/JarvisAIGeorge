---
name: planning-and-task-breakdown
description: Turn a spec into ordered, verifiable vertical slices that map 1:1 to pull requests, issue-tracker tickets and worker briefs. Brief mode by default (per slice goal, done check, how to verify, blocking edges, likely files, size). Full mode only when earned (a multi-PR series, cross-package rollout ordering, or work bigger than one session) adds a design contract, rollout table and a decision list. Plan mode, no code. Never overwrites an unfinished plan; a re-plan appends a revision. Use when the user says "plan", "break this down", "slice this", "what are the PRs", "plan the series", "deepen the plan", or after spec settles what we are building.
---

# Plan

Cut the spec into slices that each end green, in an order that proves itself. One slice, one PR, one ticket, one brief.

## When to use

- A spec exists (brief or full) and the work needs more than one PR, or the order is not obvious.
- Work will be split across workers, subagents or sessions.
- The user says "plan", "break this down", "what are the PRs", "deepen the plan".

Not for:

- One-PR changes. The spec's done check is the plan.
- No spec yet: run `spec-driven-development` first. Fuzzy intent: `grill-me`. Open choice of approach: `brainstorm`.

The chain is `grill-me` (what you want) -> `brainstorm` (which option) -> `spec-driven-development` (how, and the check) -> `planning-and-task-breakdown` (in what order, as which PRs).

## Plan mode, no code [bl: strong]

Read before you cut: the spec, the code each slice touches, the project conventions, sibling code and git history. Do not edit code. The output is the plan, nothing else. Facts you can look up are yours to find; ask only what the spec left open, each question with a recommended answer.

## Pick the mode [bl: strong]

Brief is the default. Go full only when at least one is true:

- A multi-PR series where later PRs rely on seams an earlier one adds.
- Rollout ordering across packages or environments matters (code deployed before config, a migration before its reader).
- The work is bigger than one session and still has open decisions.
- The spec was full mode.

Say which mode and why in one line.

## Slicing rules

- **Vertical, not horizontal.** Each slice is a narrow but complete path that can be checked on its own, not "all the config, then all the code". [bl: strong]
- **Every slice ends in a verifiable state.** Its CI is green and its named check passes before the next slice builds on it. A slice that cannot be checked alone is not a slice. [bl: invariant]
- **One slice, one PR.** Split when the title needs "and", the done check needs more than three bullets, it spans two independent subsystems, or it is XL. Sizes: XS one file, S one or two, M three to five, L five to eight, XL split. [bl: strong]
- **Make the change easy, then make the easy change.** Prefactor and zero-behavior-change slices come first, for example a new setting whose default is today's value, before the slice that flips it. [bl: strong]
- **Blocking edges include deploy edges.** "Merges after S1" and "merges after S1 is deployed to production" are different edges. Name the environment. A slice is blocked only by what truly gates it. [bl: invariant]
- **Order the series as an argument.** Failing test before the fix, baseline before the treatment, scaffold before the feature, riskiest unknown early so it fails fast. [bl: soft]
- **Wide refactors are the exception.** One mechanical change that breaks many call sites goes expand, migrate in batches (one PR each, blocked by the expand), then contract (blocked by every batch). [bl: strong]

## Mode 1: Brief (default)

One block per slice. Each field is one line.

```
### S<n>: <title, no "and">
Goal: <what this slice makes true>
Done check: <a check that can fail>
Verify: <CI on the PR + the named test, metric or command>
Blocked by: <S<n> | S<n> deployed to <environment> | D<n> | none>
Files: <likely paths, one job each>
Size: <XS | S | M | L>
Maps to: PR "<title>" (<package>) | ticket "<title>" | brief <id>
```

Then:

- **Frontier:** the slices with no open blockers. They can start now.
- **Checkpoints:** after every two or three slices, and after every deploy edge, a line saying what must be true before going on (CI green, the metric reads right in staging, the user has looked).
- **Index:** once PRs and tickets exist, the plan keeps an ordered list of their links, not a second checklist.

## Mode 2: Full (when earned)

Everything in brief, plus:

1. **Header.** Goal, spec link, and the spec's global constraints copied verbatim. Every slice inherits them.
2. **Design contract.** Link the spec's design contract when it has one; otherwise write it here: invariants that hold across the series, and an ownership table (PR, owns, must not touch, seam it uses or adds). Every worker brief in the series links it and requires reading it. [bl: invariant]
3. **Interfaces per slice.** For slices others depend on: consumes (what it uses from earlier slices) and produces (the names, signatures and config keys later slices rely on). A worker sees only its own slice, so this is how it learns its neighbors. [bl: strong]
4. **Rollout table.** Slice, package, merge after, deploy after, what a rollback of this slice leaves behind. [bl: strong]
5. **Risks and open questions.** Risk, impact, mitigation. Each open question with a recommended answer and the slice it blocks.
6. **Decision list, for work bigger than one session.** [bl: strong]
   - Destination: what reaching the end looks like, in one or two lines.
   - Decisions so far: one line each, linking where the detail lives.
   - Open decisions `D<n>`: the question, its type (research, prototype, grill, task), and what blocks it. A slice that needs a decision is blocked by it.
   - Not yet specified: the coming questions you cannot phrase sharply yet. Do not slice the fog.
   - Out of scope: work past the destination. Never blank.
   - Resolve one decision per session (research decisions may fan out in parallel). Record the answer, then graduate whatever fog it cleared into new decisions or slices.

## Outputs map 1:1 [bl: strong]

| Slice field | PR | Ticket | Worker brief |
|---|---|---|---|
| Title | title | title | id and title |
| Goal | description summary | description | Goal |
| Done check | test plan | acceptance criteria | Done check |
| Verify | testing section | acceptance criteria | Proof wanted |
| Blocked by | "Depends on" line | the tracker's blocking link | Constraints ("do not start until ...") |
| Plan link | description links the slice | description links the plan | Plan section: plan doc and design contract, required reading |

- Tickets go to the project's issue tracker, under the parent issue or epic the project uses, with the tracker's native blocking links where it has them.
- Briefs follow the `spec-driven-development` brief format plus the Plan section. A brief never tells a worker to skip the plan or its design contract. Out of scope in a brief names the other slices.
- **Offered, never automatic.** Creating tickets or dispatching workers is an external write: ask "Create N tickets under X?" and "Start S1 (frontier)?" and act only on a yes. [bl: invariant]

## Where it lives

- Next to the spec. A brief plan is a `## Plan` section in the spec doc. A full plan is a sibling `docs/plans/<topic>.md` that links the spec, committed with the code.
- Non-interactive runs write the plan into the report.

## Never overwrite an unfinished plan [bl: invariant]

Before writing, look for an existing plan with open slices.

- Same work, re-planned: keep every slice and its number, mark done ones done, and append `## Revision <n> (<date>): <what changed and why>`. Update the index.
- Different work: stop and ask (finish the old plan, discard it explicitly, or put the new one elsewhere). Non-interactive runs write the new plan to a new file and report the conflict.
- Never close, delete or reparent another plan's open tickets or PRs to make room.

## Deepen and review (optional) [bl: strong]

- **Deepen** ("deepen the plan"): walk each slice against the template and fill the gaps: a done check that cannot fail, a missing deploy edge, an interface a later slice assumes, a slice that is really two. Record it as a revision.
- **Review:** send a full plan to a fresh-context reviewer with an engineering lens:
  - What already solves each sub-problem? Reuse beats a new slice.
  - What is the minimum set of slices that reaches the goal? Defer the rest.
  - Count files and new classes. More than about eight files or two new classes earns a challenge.
  - Any failure mode with no test, no error handling, and a silent outcome is a critical gap.
  - Is each slice verifiable alone, and is each blocking edge real?
- Brief plans skip review unless a constraint asks for it.

## Executing the plan [bl: strong]

- Work the frontier. Mark a slice done only when its CI is green and its done check passed, with the PR link.
- A deviation is decided, not stalled on: record it as a revision with what was decided, why, and the cost if wrong, then keep going. Stop only for one-way doors (production, publish, delete).
- Parallelize only slices that touch different files or packages. If two slices share a contract, the contract slice goes first.

## Non-interactive runs

Workers and loops have no live user. Write the plan into the report, take the recommended answer on two-way doors and log it as an assumption, leave one-way doors as open decisions, and do not create tickets or start workers. This matches rule 2 of `start-playbook`.

## Red flags

- A slice whose done check cannot fail, or with no Verify line.
- Horizontal slices ("all config", "all tests") or a slice titled with "and".
- A config or flag flip in the same slice as the code that reads it, with no deploy edge or ordering note.
- A full plan with no design contract, or a worker brief that skips it.
- An unfinished plan rewritten in place, or done slices renumbered.
- Tickets created or workers started without a yes.
- "It passed on my machine" as the Verify line.

## Worked example (brief mode)

A service health check that today fails a host only when all of its workers are degraded.

Spec (brief): Goal: a host fails its health check when at least 80% of its monitored workers are degraded, not only at 100%. Done check: on a host with 23 workers, 19 degraded fails and 18 does not; zero monitored workers never fails. Proof wanted: CI, unit tests at the edges, the new threshold metric in staging. Out of scope: the fleet-wide minimum-healthy gate.

Mode: brief. Two packages and one deploy edge, no new seams.

```
### S1: Add a degraded-workers percentage threshold, default 100
Goal: the health check reads a 1..100 threshold; at 100 decisions match today
Done check: unit tests: 100 matches old decisions; 80 fails at 19/23 and 10/12, not at 18/23; zero monitored never fails
Verify: CI on the PR + coverage on new lines
Blocked by: none
Files: the health check config class, the degraded-worker tracker, their tests
Size: S
Maps to: PR "Fail health at a degraded-workers percentage" (service) | ticket "Health check at 80% degraded" | brief degraded-workers-pct

### S2: Set the threshold to 80 in staging and three production regions
Goal: those environments fail at 80, every other one stays at 100
Done check: config resolves 80 there and 100 elsewhere; the environment that disables the check keeps it disabled
Verify: CI on the PR; after the staging deploy, the threshold metric reads 80
Blocked by: S1 deployed to staging and those regions
Files: the deployment config package
Size: XS
Maps to: PR "Health check at 80% degraded" (deployment config) | same ticket | same brief
```

Frontier: S1. Checkpoint: after S2 reaches staging, the threshold metric reads 80 and the threshold-reached metric stays quiet before production.

`## Revision 1`: an ordering check found older builds ignore an unknown config key, so any merge or rollback order yields 100 or 80. The deploy edge on S2 dropped and S2 folded into S1's PR. S1 and S2 kept their numbers.

`## Revision 2`: review asked that the tracker report the real degraded workers and that the threshold move into the health evaluator. S1's files changed; its done check did not.

## Sources

- [addyosmani/agent-skills `planning-and-task-breakdown`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/planning-and-task-breakdown/SKILL.md) at `aeac41d`, MIT (see `THIRD_PARTY_LICENSE-agent-skills`): plan mode with no code, dependency graph, vertical slicing, the task template and sizes, checkpoints, the plan as an index of tracker links, never overwrite an incomplete plan.
- [mattpocock/skills `to-tickets`](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/to-tickets/SKILL.md) and [`wayfinder`](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/wayfinder/SKILL.md) at `5beb35b`, MIT (see `THIRD_PARTY_LICENSE-mattpocock-skills`): tracer-bullet slices with blocking edges, prefactor first, expand-migrate-contract for wide refactors, the frontier; the decision map with destination, decisions so far, fog, out of scope, one decision per session.
- [obra/superpowers `writing-plans`](https://github.com/obra/superpowers/blob/2ce8aa15d05bd57213e6f746f953aafb7ded7a8b/skills/writing-plans/SKILL.md) and [`executing-plans`](https://github.com/obra/superpowers/blob/2ce8aa15d05bd57213e6f746f953aafb7ded7a8b/skills/executing-plans/SKILL.md) at `2ce8aa1`, MIT (see `THIRD_PARTY_LICENSE-superpowers`): write for an engineer new to the code, global constraints copied verbatim, consumes and produces per task, the smallest unit with its own test cycle, rulings instead of stalls.
- [EveryInc/compound-engineering-plugin `ce-plan`](https://github.com/EveryInc/compound-engineering-plugin/blob/6500180a95ee132d612c58ceb6cb2fffe40766e6/skills/ce-plan/SKILL.md) at `6500180`, MIT (see `THIRD_PARTY_LICENSE-compound-engineering-plugin`): depth sized to the work, deepening an existing plan.
- [garrytan/gstack `plan-eng-review`](https://github.com/garrytan/gstack/blob/576839cb8ce73c08a05a71efa91e80ca19fa630b/plan-eng-review/SKILL.md) and `autoplan` at `576839c`, MIT (see `THIRD_PARTY_LICENSE-gstack`): the review lens (what already solves it, minimum change, complexity count, silent failure modes as critical gaps).
- [cursor/plugins pstack `principle-sequence-verifiable-units`](https://github.com/cursor/plugins/blob/10d7b8a647caedfca8143ca8335d9e063c027227/pstack/skills/principle-sequence-verifiable-units/SKILL.md) and `swarm` at `10d7b8a`, MIT (see `THIRD_PARTY_LICENSE-pstack`): every unit ends in a verifiable state, order the delivery as an argument, standalone briefs per worker.
- Rewritten here, not copied. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
