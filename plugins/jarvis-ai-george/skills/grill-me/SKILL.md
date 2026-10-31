---
name: grill-me
description: Interview the user until you know what they actually want, or until every decision in a plan is settled. Two modes, picked automatically. Intent mode when the ask is fuzzy ("build me X" with no who, why, or success). Design mode when a plan or design exists and needs stress-testing. Asks in rounds with a recommended answer for every question, looks up facts itself, and ends with a confirmed intent block. Use when the user says "grill me", "interview me", "are we sure?", "stress-test this", or when you catch yourself filling in missing requirements before any plan or code exists.
---

# Grill Me

Find the gap between what the user asked for and what they want, before anything is built. Facts are yours to find. Decisions are theirs.

## When to use

- The ask is missing a who, a why, a success test, or the binding constraint.
- A plan or design exists and the user wants it stress-tested.
- The user says "grill me", "interview me", "are we sure?".

Skip it for unambiguous asks (rename, typo), pure information requests, or when the user asked for speed over checking.

## Pick the mode [bl: strong]

- **Intent mode** (no plan yet): the questions are who, why now, what success looks like, what limits it, what is out of scope.
- **Design mode** (a plan, spec, or design exists): map it as a design tree. Each decision branches into the decisions that hang off it. Questions walk the tree.

Say which mode you picked in the first line. Switch if the answers show you picked wrong.

## Step 1: Hypothesis and confidence

Before any question, write:

```
HYPOTHESIS: <one sentence: what you think they want>
CONFIDENCE: ~<n>%, missing: <what is still unknown>
```

The number must be one you can defend. If you cannot predict their reaction to your next three questions, it is too high.

## Step 2: Facts are your job [bl: invariant]

- Never ask the user something you can look up: code, config, docs, history, tickets, logs.
- Look it up yourself, or send a subagent for a slow lookup.
- Do not block on it. A running lookup is an open prerequisite: only the questions that depend on it wait. Ask the rest now.
- State any fact you inferred so the user can correct it.

## Step 3: Ask in rounds [bl: strong]

The **frontier** is every question whose prerequisites are settled. Ask the frontier, at most 4 questions per round, then wait.

- Each question carries your recommended answer first, worded so "yes" accepts it.
- A question that depends on another open question in this round goes in a later round.
- In Claude Code, use the AskUserQuestion tool: one question per item, the recommended option first with "(Recommended)" in its label.
- Elsewhere, plain numbered text:

```
Q1. <question>
Recommended: <answer>. <one-line reason>
```

After each round, fold the answers in, update HYPOTHESIS and CONFIDENCE, and recompute the frontier. Settled answers push it outward. Reopen an earlier answer if new information breaks it.

## Step 4: Want vs should want [bl: soft]

Watch for answers that sound like a good answer instead of a real one: buzzwords ("scalable", "clean", "modern"), deference to convention ("the standard way"), or "I should probably...". When you hear one, ask:

> If you didn't have to justify this to anyone, what would you actually want?

## Step 5: Stop test [bl: strong]

Stop asking when both hold:

1. You can predict the user's answers to your next 3 questions.
2. The frontier is empty: every branch visited, nothing silently assumed.

If several rounds pass and confidence is not rising, stop and say so: something foundational is missing, ask whether to step back.

## Step 6: Restate [bl: strong]

```
Here's what I now think you want:
- Outcome:      <one line>
- User:         <who benefits>
- Why now:      <what changed>
- Success:      <how we know it worked>
- Constraint:   <the binding limit>
- Out of scope: <what we are explicitly not doing>
Yes / no / refine?
```

- Out of scope is required, never blank. Half of misalignment is silent disagreement about what is not being built. [bl: invariant]
- In design mode, add one line per settled decision under the block.

## Step 7: Explicit yes [bl: invariant]

Only an explicit yes confirms. These are not yes:

- "Whatever you think": delegation. Re-ask as a choice between two concrete options.
- "Sounds good", "sure, let's go": ask "Anything you'd refine?"
- Silence, then "ok let's start": ask what you missed.

On a correction, fold it in and restate. Do not act on the intent, write a spec, or start work until the yes.

## Output [bl: strong]

The confirmed intent block. Then offer to save it to `docs/intent/<topic>.md`, and offer the next step (`spec-driven-development`, then `planning-and-task-breakdown` for the PRs and tickets). Save only if they agree. Stop the turn after the offer.

## Non-interactive runs [bl: strong]

Workers, loops, sweeps, and CI have no live user. Do not interview.

- Write the open questions, each with its recommended answer, into the report.
- Two-way doors (reversible): decide with your recommendation, log it as an assumption, keep going.
- One-way doors (production, publishing, deletes, data, other people's work): leave as a question in the report, keep working on everything it does not block.

This matches rule 2 of `start-playbook`.

## Red flags

- A question with no recommended answer.
- Asking the user for a fact you could have looked up.
- More than 4 questions in a round, or a question that depends on another open one.
- Accepting a buzzword or "whatever you think" as an answer.
- A restate with no Out of scope line, or acting before an explicit yes.

## Sources

- [addyosmani/agent-skills `interview-me`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/interview-me/SKILL.md) at `aeac41d`, MIT (see `THIRD_PARTY_LICENSE-agent-skills`): hypothesis and confidence, want vs should want, the restate block, the explicit-yes gate, the three-answer stop test.
- [mattpocock/skills `grilling`](https://github.com/mattpocock/skills/blob/5beb35b040e3de97e54fa9e386d7e42d15c295c2/skills/productivity/grilling/SKILL.md) at `5beb35b`, MIT (see `THIRD_PARTY_LICENSE-mattpocock-skills`): design tree, rounds over the frontier, recommended answer worded so yes accepts it, facts are the agent's job, never block on a lookup. `wayfinder` for the human-in-the-loop vs agent-alone split behind the non-interactive rule.
- Rewritten here, not copied. The `[bl: ...]` tags are analysed in `BITTER_LESSON.md`.
