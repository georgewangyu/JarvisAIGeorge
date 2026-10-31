---
name: mistake-miner
description: The bottom-up half of the quality bar (constraints is the top-down half). Collects agent mistakes into an append-only inbox instead of fixing each one, then clusters them weekly so a human sees the repeats and picks a mechanism (architecture, type, lint, test, then agent rules) for each. Three triggers, cheapest first, a capture hook on the user's correction prompts, a daily harvest of evaluator findings, reviewer and bot comments, failed CI runs and new agent rules, and a weekly cluster that writes the review doc. Never edits code or rules itself; approved rows go to a fix step such as pstack correct. Use when the user says "mine mistakes", "mistake review", "what do agents keep getting wrong", "harvest corrections", or when the daily job or the weekly cluster runs.
---

# Mistake miner

Do not fix each mistake as it happens. Write it down, and look for the pattern once a week.

## When to use

- The daily scheduled job runs (harvest step) or it is the weekly review day (cluster step).
- The user asks what agents keep getting wrong, or for the mistake review.
- After a long correction-heavy session, to backfill its signals.

Not for:

- Fixing a mistake. The miner only reads and appends. Fixes go through pstack `correct` (code, lint, tests) or an agent-rules or skill edit, as a separate task.
- Setting the bar up front. That is `quality-constraints`.

Why a buffer: when every bad pattern spawns a fix, the fixer is in execution mode and misses the shape. A queue of artifacts lets a human (or a chief-of-staff agent) see that ten findings are one class, and fix the class once.

## Files

The root is a config value. `scripts/miner.py dir` prints it (default `~/.mistake-miner`). Config (`key=value`, first file found): `$MISTAKE_MINER_CONFIG`, then `~/.config/mistake-miner/config`. `$MISTAKE_MINER_DIR` overrides `dir`.

| File | What | Who writes |
|---|---|---|
| `inbox.md` | One row per signal: date, source, class, evidence, short quote. Append-only. | `miner.py append` |
| `inbox-stubs.md` | Raw correction-looking prompts from the hook. Never edited. | `capture.sh` |
| `.miner-state.json` | Stubs classified and evidence dropped, so harvest never re-offers them. | `miner.py append` |
| `review-YYYY-Www.md` | The weekly cluster table for a human to decide. | `miner.py cluster --write`, then the agent fills it |
| `rules.md` | Approved rules: rule, class, origin, enforcer, proof, date. The rule-to-enforcer table. | Agent, after a human approves |

Other config keys: `reports` (glob of agent report and evaluator files, repeatable), `watch` (glob of review watch files whose rows start with a change id and list seen comment refs like `r1p2`, repeatable), `rules_file` (agent rules file whose sections carry a `Context:` line), `prompts` (prompt history jsonl, for backfill, for example `~/.claude/history.jsonl`), `review_url` (link template with `{id}`).

## Trigger 1: capture hook (event, no LLM) [bl: strong]

`scripts/capture.sh` runs on every user prompt (a `UserPromptSubmit` hook in Claude Code: `bash <skill>/scripts/capture.sh`). Pure bash, about 30 ms, prints nothing, always exits 0. It appends one stub (time, id, session, cwd, first 200 chars) when the prompt matches a correction phrase: a leading "no", "nope", "wrong" or "stop", or "don't", "I said", "that's not", "why did you", "you forgot", "again", "stop doing".

It skips machine prompts (starting with `<`, a brief line, a wake line) and anything that looks like a secret (key prefixes, `password=`, long token runs). `MISTAKE_MINER_CAPTURE=off` turns it off; set it for worker or subagent sessions so only the human's prompts count. Stubs are noisy by design. Classification happens in the harvest.

## Trigger 2: daily harvest (scheduled) [bl: strong]

Runs as a step of an existing daily job (a cron or scheduled agent run), not a new scheduler.

1. `python3 scripts/miner.py harvest --days 1` prints candidate rows (TSV) not already in the inbox or dropped:
   - **eval**: Critical, High and Medium concerns in evaluator findings files (paths with `eval`).
   - **dry-run**: failed or red CI (dry-run) lines in agent reports.
   - **review**: comment refs from the review watch file. Fetch each comment's text and author from the code review tool. Drop the user's own replies and bot boilerplate. Keep review-bot findings and coverage failures.
   - **steering**: agent-rules sections with a `Context:` line dated in the window.
   - **hook**: unclassified stubs.
2. For each candidate, set the class from `references/classes.md` (prefer an existing slug; add a new one only when nothing fits) and a short quote. Set class `drop` for a redirect, a new decision, a question, or the user's own text. A redirect changes the plan ("use 80 not 70", "someone else owns that"); a correction says the agent did something wrong ("I said let it run", "why did you publish").
3. Count a finding once per incident: when the same eval finding repeats across rounds of one change, keep the first and drop the rest.
4. Pipe the rows back: `python3 scripts/miner.py append` (stdin TSV: date, source, class, evidence, quote, stub id).
5. Append only. Do not fix, reply, or post anything.

`--backfill-prompts --days 14` adds the prompt history as a source, for a first run or a gap.

## Trigger 3: weekly cluster (Friday morning) [bl: strong]

1. `python3 scripts/miner.py cluster --write` writes `review-<this week>.md`: one row per class with 3 or more hits all time and at least one this week, with counts (week / all time) and up to 3 evidence links. One-offs and retire candidates (rules with no hit in 90 days) go below the table. It never overwrites an existing review.
2. Fill **Mechanism** for each row, in pstack order, and say why a higher level does not work:
   1. Architecture (one owner, one way, delete the old way)
   2. Type (the bad state cannot be written)
   3. Lint or CI check whose error names the fix
   4. Test of the behavior
   5. Agent rules or skill text, only for judgment calls
3. Fill **Proof plan**: which past instance from the evidence the new check must fail on.
4. Mark a row `repeat` when `rules.md` already has a rule for that class (the script does this). A repeat means the existing enforcer is too weak: propose a higher level.
5. Leave **Decision** blank for the human: approve, reject, or later.
6. Surface it as one line in the user's start-of-day summary on review day.

Keep the doc short: the table, one-offs, retire candidates. No essay.

## After the human decides [bl: invariant]

- **approve**: append the rule to `rules.md` (rule, class, origin `mined: <evidence link>`, enforcer, proof, date) and start pstack `correct` (or an agent-rules or skill edit for level 5) with the row as the brief. The check must fail on the named past instance before the rule counts.
- **reject**: note why in the Decision cell. The signals stay in the inbox.
- **later**: carry the row; next week's counts will show if it grew.
- **retire**: delete a rule only when its mistake can no longer happen (pstack: drop a rule once its mistake is impossible).

## Red flags

- The miner edited code, agent rules, or an old inbox row.
- A cluster proposed at rules-text level with no reason why lint, type, or test fails.
- A rule in `rules.md` with no proof instance.
- The inbox is full of redirects (classification too loose) or empty after a correction-heavy week (hook or harvest broken).

## Verification

- [ ] `python3 -m unittest discover -s skills/mistake-miner/tests` passes (hook match, skips, speed, harvest sources, dedupe, cluster threshold, repeat and retire).
- [ ] The daily harvest appended rows with evidence links and no fixes.
- [ ] The weekly review has Mechanism and Proof filled for every row and a blank Decision.

## Sources

- Lauren Tan, [pstack talk](https://www.youtube.com/watch?v=kGXnNfmvhv4) (about 1:37:00 to 1:38:30): an agent appends bad patterns to a document instead of fixing them; every few days she reviews it and sees they are the same thing. The buffer plus periodic human pattern review is this skill.
- [cursor/plugins pstack `correct`](https://github.com/cursor/plugins/tree/9580c23696ac8d7abed0c166f2f9918800afb819/pstack/skills/correct) and `reflect`, MIT (`THIRD_PARTY_LICENSE-pstack`): a class counts once it repeats, the architecture > type > lint > test > docs ladder, prove each check on a real past mistake, the rule-to-enforcer table, and reflect's Accepted / Rejected / Backlog routing with human approval before any edit. Rewritten, not copied.
- [addyosmani/agent-skills `constraint-driven-development`](https://github.com/addyosmani/agent-skills/blob/aeac41d4d005999432bb7312f7ff06383a91d59d/skills/constraint-driven-development/SKILL.md), MIT (`THIRD_PARTY_LICENSE-agent-skills`): the top-down half; mined rules land in the same bar with origin `mined`.
- Compared, no mining loop (safety rails or verify-before-done only): gstack `careful` / `guard` / `freeze`, mattpocock/skills `git-guardrails-claude-code`, superpowers `verification-before-completion`, compound-engineering `ce-compound` (captures learnings per task, no cross-task clustering), kunchenguid/no-mistakes.
- `references/classes.md` starts from a sort of about 160 reviewer comments on one service's changes into 18 classes, plus agent-behavior classes.
- Short `[bl: invariant|strong|soft]` tags mark bitter-lesson risk; the analysis is in `BITTER_LESSON.md`.
