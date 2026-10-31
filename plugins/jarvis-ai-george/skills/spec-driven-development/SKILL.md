---
name: spec-driven-development
description: Write down what we are building before building it. Brief mode by default, five one-line fields (goal, done check, proof wanted, what we know, constraints) plus out of scope, which is also the format for worker briefs. Full mode only when earned (one-way doors, multi-PR work, cross-team review, a new service or API) synthesizes a design doc from the settled intent and decision, with a scope check, boundaries, test seams, and a design contract for multi-PR work, then sends it to review. Use when the user says "spec", "write a spec", "brief this", "design doc", "what are we building", after grill-me or brainstorm settles a direction, or before handing work to a worker.
---

# Spec

Say the goal, the check, and the proof. Add rigor only when the change earns it.

## When to use

- A direction is settled (by `grill-me`, `brainstorm`, or the user) and someone is about to build.
- Before dispatching a worker. Its brief is a brief-mode spec.
- The user says "spec", "brief this", "design doc", "what are we building".

Not for:

- One-line fixes and mechanical changes (renames, version bumps, a config value). Just do them.
- Fuzzy intent: run `grill-me` first. Open choice between approaches: run `brainstorm` first.
- A PRD is what and why for a product. A spec is how. PRD mode is out of scope for now.

The chain is `grill-me` (what you want) -> `brainstorm` (which option) -> `spec-driven-development` (how, and how we know it worked) -> `planning-and-task-breakdown` (in what order, as which PRs).

## Pick the mode [bl: strong]

Brief is the default. Go full only when at least one is true:

- A one-way door: data format, public API, delete, migration, another team's system.
- Multi-PR work, where later PRs depend on seams an earlier one adds.
- Cross-team review is needed.
- A new service, component, or API.

Say which mode and why in one line. If unsure, write the brief first. It becomes the full spec's objective.

## Mode 1: Brief (default)

Each field is one line. Leave out the how: say what to achieve and let the builder find the path.

```
Goal: <what is wrong or what we want>
Done check: <a check that can pass or fail>
Proof wanted: <command output, metric, before/after number, video>
What we know: <repro, log line, ticket, link>
Constraints: <repro first | zero behavior change | review before merge | ...>
Out of scope: <what not to touch>
```

- The done check must be able to fail. "Make it better" or "work on it for an hour" is not a check. [bl: invariant]
- Proof wanted names the evidence, not "tests pass". It is what the report shows. [bl: invariant]
- Out of scope is never blank. Unstated non-goals are where scope creep starts. [bl: invariant]
- Hold back your theory of the cause at first. A stated guess narrows the search.
- Workers and subagents get this brief. Add the plan doc link when the work is part of a series of PRs.
- More than one PR? Run `planning-and-task-breakdown` next. It cuts the spec into slices that each map to a PR, a ticket and a brief.

## Mode 2: Full (when earned)

### Synthesize, do not re-interview [bl: strong]

Start from what is already settled: the `grill-me` intent block, the `brainstorm` decision note, the conversation, and the code. Read the code the change touches before writing. Ask only what is still missing, in one round, each question with a recommended answer. Facts you can look up are yours to find.

### Phase 0: Scope check [bl: strong]

If the ask bundles capabilities that could ship and be verified separately, split before writing. Propose a short capability map (module id, responsibility, depends on, build order) and get it confirmed. Then write one spec per module, in dependency order. One spec, one capability.

### Sections [bl: strong]

1. **Objective.** The problem, who it is for, and measurable success criteria. Reframe vague goals as numbers ("faster" -> "p99 under 200 ms at 10k TPS"). Sanity-check each number with `principles-first-principles`.
2. **Commands.** Full build, test, and run commands with flags. CI on the change is the build gate.
3. **Structure.** Where the code, tests, and docs live. The files and modules to create or change, one job each.
4. **Boundaries.** [bl: invariant]
   - Always: <for example run the tests, follow the package conventions>
   - Ask first: <for example schema changes, new dependencies, prod config>
   - Never: <for example commit secrets, edit vendored code, delete failing tests>
5. **User stories.** "As a <actor>, I want <feature>, so that <benefit>." Numbered, covering the edges, not only the happy path.
6. **Implementation decisions.** Modules, interfaces, contracts, schema and API shapes, and the option `brainstorm` picked with its reason. No file paths or code that will rot. A prototype snippet that pins a decision (a state machine, a type) is fine.
7. **Test seams.** Where the feature is tested. Use existing seams first and the highest seam possible. Fewer seams is better, one is ideal. Confirm them with the user before building. [bl: invariant]
8. **Out of scope.** Never blank. [bl: invariant]
9. **Open questions.** Each with a recommended answer and what it blocks.

Write for an engineer who has not seen the codebase: name what you decided (files, interfaces, values, the tests that prove each part) and leave the rest to their judgment.

### Design contract for multi-PR work [bl: invariant]

A short section later briefs can quote verbatim:

- **Invariants** that hold across the series (for example "fault handling goes only through seam X; each PR swaps the injected impl, never rewrites X").
- **Ownership table:** PR, owns, must not touch, seam it uses or adds.

Every seam a later PR relies on is named here. Every worker brief in the series links this section and requires reading it. `planning-and-task-breakdown` full mode links this section rather than copying it.

### Format and publishing

- If the project already has a design-doc template or a spec tool, map the sections above onto it; do not add a second structure.
- For a larger plan, a planning subagent can draft it in its own context.
- Save it to `docs/specs/<topic>.md` and commit it with the code.

## Review gate [bl: strong]

A full spec goes to a fresh-context reviewer twice before anyone builds: a normal pass (with the brief and context) and a blind pass (the doc only). Fix or answer every finding. Optional lenses when the stakes call for them:

- **Engineering:** architecture, data flow, edge cases, test coverage, performance.
- **Product:** is this the right problem, and is the scope too big or too small.
- **Operations:** alarms, rollback, deploy order, blast radius.

Then show the user a summary and the open questions, and stop. Building starts after their yes. A brief needs no review gate unless a constraint asks for one.

## Keep it alive [bl: strong]

- Change course in the spec first, then in the code.
- Each PR links the spec section it implements.
- When scope is added or cut, update Out of scope and the ownership table.

## Non-interactive runs

Workers and loops have no live user. Write the spec into the report, take the recommended answer on two-way doors and log it as an assumption, and leave one-way doors as open questions. This matches rule 2 of `start-playbook`.

## Red flags

- A done check that cannot fail, or no proof named.
- Full mode for a two-way change, or a brief for a one-way door.
- Re-asking what grill-me or brainstorm already settled.
- One spec covering several separable capabilities.
- New test seams where an existing one would do.
- A multi-PR series with no invariants or ownership table, or a worker brief that skips them.
- Code changed in a direction the spec does not say.

## Sources

- [addyosmani/agent-skills `spec-driven-development`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/spec-driven-development/SKILL.md) at `aeac41d`, MIT (see `THIRD_PARTY_LICENSE-agent-skills`): gated flow, Phase 0 scope check and capability map, the six areas, always / ask first / never, success criteria as numbers, keep the spec alive.
- [mattpocock/skills `to-spec`](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/to-spec/SKILL.md) at `5beb35b`, MIT (see `THIRD_PARTY_LICENSE-mattpocock-skills`): synthesize without re-interviewing, test seams (existing first, highest), the problem / user stories / implementation decisions / testing decisions / out of scope template.
- [obra/superpowers `writing-plans`](https://github.com/obra/superpowers/blob/2ce8aa15d05bd57213e6f746f953aafb7ded7a8b/skills/writing-plans/SKILL.md) at `2ce8aa1`, MIT (see `THIRD_PARTY_LICENSE-superpowers`): scope check, write for an engineer new to the codebase, file map.
- [garrytan/gstack](https://github.com/garrytan/gstack/tree/576839cb8ce73c08a05a71efa91e80ca19fa630b) at `576839c`, MIT (see `THIRD_PARTY_LICENSE-gstack`): `spec`, `plan-eng-review` and `plan-ceo-review` role lenses for the review gate.
- [EveryInc/compound-engineering-plugin `ce-plan`](https://github.com/EveryInc/compound-engineering-plugin/blob/6500180a95ee132d612c58ceb6cb2fffe40766e6/skills/ce-plan/SKILL.md) at `6500180`, MIT (see `THIRD_PARTY_LICENSE-compound-engineering-plugin`): output contracts sized to the work (brief vs durable), completion contract.
- [cursor/plugins pstack guide "Say the goal, not the ceremony"](https://github.com/cursor/plugins/blob/10d7b8a647caedfca8143ca8335d9e063c027227/pstack/docs/guide/02-poteto-mode.md) at `10d7b8a`, MIT (see `THIRD_PARTY_LICENSE-pstack`): the five brief fields, leave out the how and your theory of the cause.
- Rewritten here, not copied. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
