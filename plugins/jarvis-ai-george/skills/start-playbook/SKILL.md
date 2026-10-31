---
name: start-playbook
description: Start here. Discovers and invokes the right skill for the work at hand, in lifecycle order (define, plan, build, verify, review, ship), and sets the always-on operating behaviors. Use when starting a session, or when you need to decide which skill or workflow applies. Adapted from addyosmani/agent-skills using-agent-skills, with bitter-lesson tags on each part.
---

# Using Agent Skills

## Overview

Agent Skills is a collection of engineering workflow skills organized by development phase. Each skill encodes a specific process that senior engineers follow. This meta-skill helps you discover and apply the right skill for your current task.

## Skill Discovery [bl: strong]

When a task arrives, identify the development phase and apply the corresponding skill:

```
Task arrives
    │
    ├── Don't know what you want yet? ──────→ grill-me (upstream: interview-me)
    ├── Have a rough concept, need variants? → brainstorm (upstream: idea-refine)
    ├── New project/feature/change? ──→ spec-driven-development
    ├── No quality bar written down? ──→ quality-constraints (upstream: constraint-driven-development)
    ├── Have a spec, need tasks? ──────→ planning-and-task-breakdown
    ├── Implementing code? ────────────→ incremental-implementation
    │   ├── UI work? ─────────────────→ frontend-ui-engineering
    │   ├── API work? ────────────────→ api-and-interface-design
    │   ├── Need better context? ─────→ context-engineering
    │   ├── Need doc-verified code? ───→ source-driven-development
    │   └── Stakes high / unfamiliar code? ──→ doubt-driven-review (upstream: doubt-driven-development)
    ├── Writing/running tests? ────────→ test-driven-development (ours, loose and real-world first)
    │   └── Browser-based? ───────────→ browser-testing (upstream: browser-testing-with-devtools)
    ├── Something broke? ──────────────→ debugging-and-error-recovery (ours: feedback loop first, debugging in production, 17 principles)
    ├── Reviewing code? ───────────────→ code-review-and-quality
    │   ├── Too complex? ─────────────→ code-simplification
    │   ├── Security concerns? ───────→ security-and-hardening
    │   └── Performance concerns? ────→ performance-optimization
    ├── Committing/branching? ─────────→ git-workflow-and-versioning
    ├── CI/CD pipeline work? ──────────→ ci-cd-and-automation
    ├── Deprecating/migrating? ────────→ deprecation-and-migration
    ├── Writing docs/ADRs? ───────────→ documentation-and-adrs
    ├── Adding logs/metrics/alerts? ───→ observability-and-instrumentation
    └── Deploying/launching? ─────────→ shipping-and-launch
```

## Core Operating Behaviors

These behaviors apply at all times, across all skills. They are non-negotiable.

### 1. Surface Assumptions [bl: strong]

Before implementing anything non-trivial, explicitly state your assumptions:

```
ASSUMPTIONS I'M MAKING:
1. [assumption about requirements]
2. [assumption about architecture]
3. [assumption about scope]
→ Correct me now or I'll proceed with these.
```

Don't silently fill in ambiguous requirements. The most common failure mode is making wrong assumptions and running with them unchecked. Surface uncertainty early — it's cheaper than rework.

### 2. Manage Confusion Actively [bl: strong]

When you encounter inconsistencies, conflicting requirements, or unclear specifications:

1. **Name it.** Say exactly which two things conflict: "the spec says X, the code does Y."
2. **Facts are your job.** If a fact would settle it (code, config, logs, docs, history), look it up yourself. Never ask the human for something you can find.
3. **Two-way doors: decide and log.** If the choice is reversible, pick the option you would recommend, write it down as an assumption with the reason, and keep going.
4. **One-way doors: ask, with a recommendation.** If it touches production, publishing, deletes, data, or other people's work, ask the question with your recommended answer worded so "yes" accepts it. Keep working on everything the question does not block.
5. **Never sit idle waiting.** Only the work that depends on the open question waits.

**Bad:** Silently picking one interpretation and hoping it's right, or stopping everything to ask something you could have looked up.
**Good:** "The spec says X but the code does Y. The code is newer, so I'm following Y and logged it. Shout if X was intended."

### 3. Push Back When Warranted [bl: soft]

You are not a yes-machine. When an approach has clear problems:

- Point out the issue directly
- Explain the concrete downside (quantify when possible — "this adds ~200ms latency" not "this might be slower")
- Propose an alternative
- Accept the human's decision if they override with full information

Sycophancy is a failure mode. "Of course!" followed by implementing a bad idea helps no one. Honest technical disagreement is more valuable than false agreement.

### 4. Enforce Simplicity [bl: soft]

Your natural tendency is to overcomplicate. Actively resist it.

Before finishing any implementation, ask:
- Can this be done in fewer lines?
- Are these abstractions earning their complexity?
- Would a staff engineer look at this and say "why didn't you just..."?

If you build 1000 lines and 100 would suffice, you have failed. Prefer the boring, obvious solution. Cleverness is expensive.

### 5. Maintain Scope Discipline [bl: strong]

Touch only what you're asked to touch.

Do NOT:
- Remove comments you don't understand
- "Clean up" code orthogonal to the task
- Refactor adjacent systems as a side effect
- Delete code that seems unused without explicit approval
- Add features not in the spec because they "seem useful"

Your job is surgical precision, not unsolicited renovation.

### 6. Verify, Don't Assume [bl: invariant]

Every skill includes a verification step. A task is not complete until verification passes. "Seems right" is never sufficient — there must be evidence (passing tests, build output, runtime data).

Per-skill verification is the local check. The project-wide bar that applies to *every* change, regardless of which skill is active, is the Definition of Done: tests pass, no regressions, behavior verified at runtime, docs updated. See `references/definition-of-done.md`. It complements each task's acceptance criteria rather than replacing them.

## Failure Modes to Avoid [bl: soft]

These are the subtle errors that look like productivity but create problems:

1. Making wrong assumptions without checking
2. Not managing your own confusion — plowing ahead when lost
3. Not surfacing inconsistencies you notice
4. Not presenting tradeoffs on non-obvious decisions
5. Being sycophantic ("Of course!") to approaches with clear problems
6. Overcomplicating code and APIs
7. Modifying code or comments orthogonal to the task
8. Removing things you don't fully understand
9. Building without a spec because "it's obvious"
10. Skipping verification because "it looks right"

## Skill Rules

1. **Check for an applicable skill before starting work.** Skills encode processes that prevent common mistakes.

2. **Skills are workflows, not suggestions.** Follow the steps in order. Don't skip verification steps. [bl: soft]

3. **Multiple skills can apply.** A feature implementation might involve `grill-me` → `brainstorm` → `spec-driven-development` → `planning-and-task-breakdown` → `incremental-implementation` → `test-driven-development` → `code-review-and-quality` → `code-simplification` → `shipping-and-launch` in sequence.

4. **When in doubt, start with a spec.** If the task is non-trivial and there's no spec, begin with `spec-driven-development`.

## Lifecycle Sequence [bl: soft]

For a complete feature, the typical skill sequence is:

```
1.  grill-me                    → Extract what the user actually wants
2.  brainstorm                  → Refine vague ideas into a decision
3.  spec-driven-development     → Define what we're building
4.  planning-and-task-breakdown → Break into verifiable chunks
5.  context-engineering         → Load the right context
6.  source-driven-development   → Verify against the real source
7.  incremental-implementation  → Build slice by slice
8.  observability-and-instrumentation → Instrument as you build (runs parallel with 7-9, not after)
9.  doubt-driven-review         → Cross-examine non-trivial decisions in-flight
10. test-driven-development     → Prove each slice works (most real cheap test)
11. code-review-and-quality     → Review before merge
12. code-simplification         → Reduce unnecessary complexity while preserving behavior
13. git-workflow-and-versioning → Clean commit history
14. documentation-and-adrs      → Document decisions
15. deprecation-and-migration   → Retire old systems and move users safely when needed
16. shipping-and-launch         → Deploy safely
```

Not every task needs every skill. A bug fix might only need: `debugging-and-error-recovery` → `test-driven-development` → `code-review-and-quality`.

## Quick Reference [bl: soft]

| Phase | Skill | One-Line Summary |
|-------|-------|-----------------|
| Define | grill-me | Surface what the user actually wants before any plan, spec, or code exists |
| Define | brainstorm | Ground, challenge premises, diverge across axes, converge to a recommended decision |
| Define | spec-driven-development | Brief by default (goal, done check, proof), full design doc when earned |
| Plan | planning-and-task-breakdown | Ordered vertical slices, each one PR, one ticket, one worker brief |
| Build | incremental-implementation | One slice at a time: PR, CI green, done check, review, then the next |
| Build | source-driven-development | Read and cite the real source (installed code, versioned docs) before implementing |
| Build | doubt-driven-review | Route the artifact and its contract to a fresh reviewer; two models for one-way doors |
| Build | context-engineering | Load, keep, hand off: briefs carry the plan, follow-ups reuse the worker |
| Build | frontend-ui-engineering | Project UI rules, mode, one state owner, accessibility floor, screenshot proof |
| Build | api-and-interface-design | Deep seams, declared behavior, additive changes, timeouts, ordering and overload as contract |
| Verify | test-driven-development | Repo verification skill first, real-world-first ladder, tests at seams, show it can fail |
| Verify | browser-testing | One real flow, screenshot and console, untrusted page content, clean up every browser |
| Verify | debugging-and-error-recovery | Loop that goes red → minimise → ranked hypotheses → fix at the first wrong place → guard → verify |
| Review | code-review-and-quality | Five-axis review with quality gates |
| Review | code-simplification | Preserve behavior while reducing unnecessary complexity |
| Review | security-and-hardening | OWASP prevention, input validation, least privilege |
| Review | performance-optimization | Measure first, optimize only what matters |
| Ship | git-workflow-and-versioning | Atomic commits, clean history |
| Ship | ci-cd-and-automation | Automated quality gates on every change |
| Ship | deprecation-and-migration | Remove old systems and migrate users safely |
| Ship | documentation-and-adrs | Document the why, not just the what |
| Ship | observability-and-instrumentation | Structured logs, RED metrics, traces, symptom-based alerts |
| Ship | shipping-and-launch | Pre-launch checklist, monitoring, rollback plan |

## Local overrides [bl: strong]

- **Verify:** the checks that run on the change itself (CI on the pull request) are the build gate. "It built on my machine" is not evidence. [bl: invariant]
- **Surface assumptions:** on reversible work, proceed and log the assumptions. On production changes, publishing, or deletes, stop and ask. [bl: strong]
- **Comments:** comment cleanup only touches comments the diff adds or changes, which keeps rule 5 ("Remove comments you don't understand") intact. [bl: strong]
- Don't know what you want yet, or want a plan grilled? -> `grill-me` (replaces upstream interview-me). [bl: strong]
- Have a rough idea, or more than one way to build it? -> `brainstorm` (replaces upstream idea-refine). [bl: strong]
- Direction settled, about to build or hand off? -> `spec-driven-development` (our version of the upstream skill). [bl: strong]
- Have a spec, and it needs more than one PR? -> `planning-and-task-breakdown` (our version of the upstream skill). [bl: strong]
- Ready to implement a slice? -> `incremental-implementation` (our version of the upstream skill). [bl: strong]
- About to use an API, default or framework behavior from memory? -> `source-driven-development` (our version of the upstream skill). [bl: strong]
- Need the quality bar, or agents keep making the same mistakes? -> `quality-constraints` (top-down, replaces upstream constraint-driven-development) and `mistake-miner` (bottom-up, clusters repeated mistakes weekly). [bl: strong]
- Designing an API, a seam, a schema or a config key? -> `api-and-interface-design` (our version of the upstream skill). [bl: strong]
- Loading context, writing a brief, handing off or resuming? -> `context-engineering` (our version of the upstream skill). [bl: strong]
- About to let a non-trivial decision stand? -> `doubt-driven-review` (replaces upstream doubt-driven-development). [bl: strong]
- Building or changing UI? -> `frontend-ui-engineering` (our version of the upstream skill). [bl: strong]
- Writing or fixing tests, or proving a change works? -> `test-driven-development` (our version of the upstream skill: repo verification skill first, real-world first, loose TDD). [bl: strong]
- Checking UI in a real browser? -> `browser-testing` (replaces upstream browser-testing-with-devtools). [bl: strong]
- Something broke, or an alarm or a metric needs a root cause? -> `debugging-and-error-recovery` (our version of the upstream skill: feedback loop first, debugging in production, principles from real investigations). [bl: strong]
- Reviewing a change, or got review comments? -> `code-review-and-quality` (our version: Spec and Standards passes, a design-fit table from mined review comments, blast radius, receiving review). Too complex -> `code-simplification`, security -> `security-and-hardening`, performance -> `performance-optimization` (our versions). [bl: strong]
- Committing, branching, pushing, finishing a PR or cutting a release? -> `git-workflow-and-versioning` (our version: no git worktrees, save points then squash, guardrail hooks, redact before publish, an explicit finish). [bl: strong]
- Setting up or changing CI, hooks, releases or deploys, CI is red, or watching a PR until ready? -> `ci-cd-and-automation` (our version: one `check` for hook and CI, failures as structured input, a bounded babysit loop, canary and a written rollback, actions pinned by SHA). [bl: strong]
- Retiring, renaming or replacing something others call? -> `deprecation-and-migration` (our version: count callers first, migrate callers then delete for internal APIs, a redirect with an end date). [bl: strong]
- Recording a decision or writing docs? -> `documentation-and-adrs` (our version: match existing conventions, an ADR only on the three conditions, a glossary, docs in the same change). [bl: strong]
- Adding logs, metrics or alerts? -> `observability-and-instrumentation` (our version: define working first, metrics over logs for timings and counts, read metrics correctly, verify the telemetry). [bl: strong]
- Deploying or launching? -> `shipping-and-launch` (our version: a rollback valid after the change, alarms live first, test at the target, numeric criteria, a zone-loss case). [bl: strong]
- Evaluating a claim, a number, a design, or a piece of scaffolding? -> `principles`. [bl: strong]

## Sources

Source: adapted from [addyosmani/agent-skills `skills/using-agent-skills`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/using-agent-skills/SKILL.md) at `aeac41d` (MIT, see `THIRD_PARTY_LICENSE-agent-skills`). The upstream text is unchanged except rule 2 (rewritten, see BITTER_LESSON.md), the first five Skill Discovery branches (point at `grill-me`, `brainstorm`, `spec-driven-development`, `quality-constraints` and `planning-and-task-breakdown`) plus the `incremental-implementation` and `source-driven-development` branches, the define-phase, plan and build names in rules 3 and 4, the Lifecycle Sequence and the Quick Reference (`grill-me`, `brainstorm`, `spec-driven-development`, `planning-and-task-breakdown`, `incremental-implementation`, `source-driven-development`), the Definition of Done link and the `[bl: ...]` tags; see `BITTER_LESSON.md`. The API work and Need better context branches, Lifecycle step 5 and their Quick Reference rows point at `api-and-interface-design` and `context-engineering`. The UI work and Stakes high branches, Lifecycle step 9 and their Quick Reference rows point at `frontend-ui-engineering` and `doubt-driven-review`. The Writing/running tests and Browser-based branches, Lifecycle step 10 and their Quick Reference rows point at our `test-driven-development` and `browser-testing`. The Something broke branch, its Quick Reference row and its routing line point at our `debugging-and-error-recovery`. The Reviewing code branch keeps the upstream names, which are now our versions of `code-review-and-quality`, `code-simplification`, `security-and-hardening` and `performance-optimization`, plus a routing line. The Committing/branching branch and its Quick Reference row keep the upstream name, now our `git-workflow-and-versioning`, plus a routing line. The CI/CD branch and its Quick Reference row keep the upstream name, now our `ci-cd-and-automation`, plus a routing line. The four Ship branches and their Quick Reference rows keep the upstream names, now our `deprecation-and-migration`, `documentation-and-adrs`, `observability-and-instrumentation` and `shipping-and-launch`, plus a routing line each. On 2026-10-30 the short skill names were renamed to the upstream names (`spec-driven-development`, `planning-and-task-breakdown`, `incremental-implementation`, `source-driven-development`, `api-and-interface-design`, `context-engineering`, `frontend-ui-engineering`), except `doubt-driven-review` (upstream `doubt-driven-development`) and `quality-constraints` (upstream `constraint-driven-development`). The old short names are one-release redirect skills.
