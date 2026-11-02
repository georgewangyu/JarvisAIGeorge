---
name: principles
description: "Index of the principle skills for judging a claim, a number, a design, or agent scaffolding. Use when someone asserts something works, is fast enough, or is the cause."
disable-model-invocation: true
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
