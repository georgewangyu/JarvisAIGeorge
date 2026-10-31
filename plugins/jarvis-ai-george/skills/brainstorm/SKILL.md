---
name: brainstorm
description: Turn a rough idea or an open "how should we do X" into a decision. Grounds itself in the code and docs first, challenges the premises, generates 4 to 6 genuinely different options across different axes, prunes to 2 or 3 with pros, cons, a cost check and a recommendation, then lets the user pick or run a bakeoff of throwaway versions. Ends with a decision note (choice, assumptions with tests, Not Doing). Use when the user says "brainstorm", "ideate", "refine this idea", "what are the options", "stress-test my plan", or when you are about to build the first approach that came to mind for a non-trivial choice.
---

# Brainstorm

Find the real options before committing to one. The goal is a decision the user can defend, not a long list.

## When to use

- A rough concept needs shaping into a direction.
- A "how should we build X" question has more than one sensible answer.
- The user says "brainstorm", "ideate", "what are the options", "stress-test my plan".

Not for:

- The user does not yet know what they want (who, why, success): run `grill-me` first.
- The direction is chosen and needs requirements: go to `spec-driven-development`.
- A routine choice with one obvious answer: say so and do it.

The chain is `grill-me` (what you want) -> `brainstorm` (what the options are) -> `spec-driven-development` -> `planning-and-task-breakdown`.

## Step 0: Ground first [bl: invariant]

Before your first message, read what bears on the idea: the code it touches, data, docs, tickets, and the earlier conversation. Keep reading until you can say how the relevant parts work today and what the change would touch.

- Never ask what that context already answers.
- If a premise or option depends on a fact you can look up, look it up (or send a subagent) instead of asking.
- Say what you found that changes the question: a constraint, a conflict, a cheaper path.

## Step 1: Premise challenge [bl: strong]

Restate the idea as one problem line ("How might we ..."). Then list the premises the options will rest on:

```
PREMISES:
1. <statement> (the problem is real: what happens if we do nothing?)
2. <statement> (this is the right framing, not a symptom of something simpler)
3. <statement> (what existing work already covers, and what it leaves)
```

Confirm them in one question. In Claude Code use AskUserQuestion, recommended answer first. If a premise is rejected, revise and loop back. Do not generate options on premises the user has not accepted.

## Step 2: Diverge [bl: strong]

Generate 4 to 6 options that are genuinely different, not variations on one theme.

- **Axes first.** Name 3 to 5 aspects of the subject (for example data model, interaction, rollout, who acts). Spread the options across them. If every option sits on the same axis, decompose again.
- **Lenses.** Inversion, constraint removal, audience shift, combination, 10x simpler, 10x scale, expert lens. Pick the ones that fit; `references/frameworks.md` has more.
- **Sharpen.** Ask what a top professional in this field would do that nobody asked for, what raw material they would start from, and what outside the conversation would prove the option right.
- Each option gets one line on why it exists.

Workers and loops run this step without the user. For more diversity, send 2 or 3 parallel subagents, each given a different axis or lens and the same grounding, then merge and dedupe.

## Step 3: Converge [bl: strong]

Prune to 2 or 3. Drop options that work against why the user wants this, and options the existing work rules out. Say in one line why each dropped option went.

For each survivor:

```
A) <name> (recommended)
   Pros: <at least 2, specific to this project>
   Cons: <at least 1, honest>
   Cost check: <a first-principles bound: latency, throughput, money, effort>
   Key assumption: <what must be true for this to win>
   Door: two-way | one-way (<what cannot be undone>)
```

- Run the cost check with `principles-first-principles`: rough numbers from the physics of the system, not adjectives.
- Recommend exactly one, with the deciding reason. If one way is clearly right, say so and explain why the others do not fit.
- Mark one-way doors (data formats, public APIs, deletes, other teams' systems). A one-way door is never auto-picked. [bl: invariant]
- Be honest, not supportive. Call a weak option weak. `references/refinement-criteria.md` has the full rubric (user value, feasibility, differentiation).
- When the options would look different (a screen, a flow, a layout, a structure), offer a visual (a mockup, diagram, or side-by-side page in any visual companion) before asking.

## Step 4: Pick or bake off [bl: strong]

Ask the user to pick, recommended option first. If they cannot choose from description alone, offer a bakeoff:

- Build 2 or 3 throwaway versions, one per option, each in its own scratch location (a worktree or `/tmp/brainstorm-<topic>/<option>/`). Same brief for each.
- Throwaway means no tests, no polish, clearly named as a prototype. Logic questions get a small runnable demo; look-and-feel questions get side-by-side variants.
- Compare against the criteria named before building, not on feel. Pick a base, graft the one or two best parts of the others by hand, and say what was rejected.
- Keeping a prototype is a new request, not a side effect.

## Step 5: Decision note [bl: strong]

```markdown
# <Topic>

## Problem
<the How-might-we line>

## Decision
<the choice, and why it beat the others, 1 to 3 short paragraphs>

## Options considered
<one line each: name, why not chosen>

## Assumptions to test
- [ ] <assumption>: <how to test it, and what result would change the decision>

## Not Doing
- <thing>: <reason>

## Open questions
- <question that must be answered before building>
```

- Every assumption has a test. An untested assumption is the most common way a good choice fails. [bl: invariant]
- Not Doing is required, never blank. It is where the trade-offs become explicit. [bl: invariant]
- Offer to save it to `docs/ideas/<topic>.md`, and offer the next step (`spec-driven-development`). Save only if they agree.

## Non-interactive runs [bl: strong]

Workers, loops, and sweeps have no live user. Run steps 0 to 3 and write the decision note into the report with the recommendation as the provisional choice. Two-way doors: take the recommendation and log it as an assumption. One-way doors: leave as an open question and keep working on what it does not block. This matches rule 2 of `start-playbook`.

## Red flags

- Asking a question the code or docs already answer.
- Options before the premises were accepted.
- Six options that are one idea with different names, or all on one axis.
- A survivor with no con, or a cost claim with no number.
- No recommendation, or a one-way door picked without the user.
- A decision note with no Not Doing list or untested assumptions.
- More than 8 options. Quality beats count.

## Sources

- [addyosmani/agent-skills `idea-refine`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/idea-refine/SKILL.md) at `aeac41d`, MIT (see `THIRD_PARTY_LICENSE-agent-skills`): How-might-we framing, the lenses, cluster then stress-test, assumptions, Not Doing. `references/` holds his `frameworks.md`, `refinement-criteria.md` and `examples.md` verbatim.
- [obra/superpowers `brainstorming`](https://github.com/obra/superpowers/blob/2ce8aa15d05bd57213e6f746f953aafb7ded7a8b/skills/brainstorming/SKILL.md) at `2ce8aa1`, MIT (see `THIRD_PARTY_LICENSE-superpowers`): look before you ask, lay out the approaches and drop the weak ones, show instead of tell.
- [garrytan/gstack `office-hours`](https://github.com/garrytan/gstack/blob/576839cb8ce73c08a05a71efa91e80ca19fa630b/office-hours/SKILL.md) at `576839c`, MIT (see `THIRD_PARTY_LICENSE-gstack`): premise challenge, option format with pros and cons, one-way-door gate.
- [EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin/tree/6500180a95ee132d612c58ceb6cb2fffe40766e6/skills) at `6500180`, MIT (see `THIRD_PARTY_LICENSE-compound-engineering-plugin`): `ce-ideate` axis decomposition, `ce-bakeoff` competing versions then synthesis, `ce-pov` grounded judging.
- [cursor/plugins pstack](https://github.com/cursor/plugins/tree/10d7b8a647caedfca8143ca8335d9e063c027227/pstack/skills) at `10d7b8a`, MIT (see `THIRD_PARTY_LICENSE-pstack`): `sharpen` questions, `arena` pick a base and graft, `principle-exhaust-the-design-space`.
- [mattpocock/skills `prototype`](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/engineering/prototype/SKILL.md) at `5beb35b`, MIT (see `THIRD_PARTY_LICENSE-mattpocock-skills`): throwaway prototypes that answer one question.
- Rewritten here, not copied, except the three reference files. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
