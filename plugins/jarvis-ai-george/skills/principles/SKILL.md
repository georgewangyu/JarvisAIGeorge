---
name: principles
description: Index of the principle skills, the evaluation methods for a claim, a number, a design, or a piece of agent scaffolding. Use when someone says "this works", "we can hit that throughput", "this is the bottleneck", "the fix is in", "is this design right", "does this violate the bitter lesson", or before trusting any result. Points to principles-scientific-method, principles-first-principles, and principles-bitter-lesson.
---

# Principles

Durable reasoning methods for judging whether something is true, possible, or worth keeping. Pick by what you are evaluating.

| You are evaluating | Use | Core question |
|---|---|---|
| A claim that something works, a fix, a root cause, a tuning result | [`principles-scientific-method`](../principles-scientific-method/SKILL.md) | What result did I predict, and what would prove me wrong? |
| A number, a capacity or throughput target, a limit, a "this is the bottleneck" | [`principles-first-principles`](../principles-first-principles/SKILL.md) | What is the physical bound, and how far is the claim from it? |
| Agent scaffolding: a skill, rule, steering doc, eval, lint, harness | [`principles-bitter-lesson`](../principles-bitter-lesson/SKILL.md) | Would we still need this if the model were 10x smarter? |

They combine. A benchmark result usually needs both: first principles to say what was possible, scientific method to say what was shown.

## Related

Lauren Tan's [pstack](https://github.com/cursor/plugins/tree/main/pstack) has principle skills that pair well with these: fix root causes, prove it works, explain the number, and attack the premise. Use them from upstream. They are not copied here.

## Exemption

Principle skills are reasoning methods, not scaffolding for a weak model. They carry no `[bl: ...]` tags, no `BITTER_LESSON.md`, and stay out of `bitter-lesson.allowlist`. See `principles-bitter-lesson`.
