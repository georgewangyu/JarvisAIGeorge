# Mistake classes

Starter vocabulary for the inbox `class` column. Prefer an existing slug. Add a new one only when nothing fits, and add it here in the same change. The weekly cluster counts by slug, so two names for one class split its count.

## Code and change content

| Slug | Means | Example signal |
|---|---|---|
| parallel-scaffolding | A new class or path beside an existing seam | "can we implement the existing assigner instead?" |
| responsibility | Logic in the wrong owner, leaking abstraction | "why this controller and not the assigner?" |
| mode-flag | Branching on a flag or on which impl is held | "can this be config controlled instead?" |
| changed-semantics | An existing metric, method or field changes meaning without a new name | "keep the purpose of this method the same?" |
| no-why | A behavior change with no stated reason | "why change this from static to instance?" |
| dead-code | Unused params, knobs with no caller, YAGNI | "why do we need a trigger for start/stop?" |
| wrong-value | A threshold, floor, bound or count that is wrong or hand-computed | "80 percent leaves one host of headroom" |
| magic-values | A literal with no name or source | "is there an existing analog for 15 seconds?" |
| naming | Undefined or inconsistent terms | "what does reseat mean? use the same lingo" |
| javadoc | Doc comment jargon, wrong, or missing | "would appreciate docs on the cases here" |
| wrong-description | A comment, caption, commit message or change description that contradicts the code or data | "caption cites the wrong metric" |
| logging-vs-metrics | Logged where a metric belongs, or the reverse | "log the time to metrics instead" |
| concurrency-errors | Thread safety, swallowed errors, lost failures | "is this thread safe?" |
| control-flow | Convoluted branching | "a better way to organize the if/else chain?" |
| performance | Cost at scale | "reconcile storm" |
| api-type | Wrong type or API choice | "do we need Optional here?" |
| imports-fqn | Inline fully qualified names, import order | "remove the full name everywhere" |
| test-quality | Missing, weak, wall-clock or coverage-failing tests | "any test that the supplier is shut down?" |
| lint-late | Style or lint failure found only at the build gate | "CI failed on operator wrap" |
| dashboard-graph | A graph that cannot show the signal (axis, scale, missing series) | "axis clips the slow-stop zone" |
| rollout-ordering | Takes effect before its dependency, no shadow mode, wrong default | "ICN is switched now, but must wait for the release" |
| scope-creep | Work beyond the ask, or a separate change folded in | "should be in a separate PR?" |
| plan-drift | A later change in a series departs from the plan's seam | "aren't we relying on the plan's helper?" |
| runbook | A runbook that is wrong, missing, or should be its own page | "create a separate runbook" |
| repeat-flagged-bug | A bug a reviewer or bot already flagged comes back | "brings back the deadlock the review bot flagged" |

## Agent behavior

| Slug | Means | Example signal |
|---|---|---|
| ignored-instruction | Did the opposite of an explicit instruction | "I said let it run" |
| forgot-item | Dropped part of the ask | "your report covers only the first item" |
| misread-ask | Built a different thing than asked | "an average of each line, not one blended line" |
| overbuilt | A heavy path where a known simple one exists | "why not just edit and bounce like last time?" |
| overstepped-scope | Touched something the user owns or is editing | "stop editing that file, I am on it" |
| idle-while-running | Ended a turn with live work unwatched | "load is on and you are not watching" |
| unsafe-shortcut | A bypass or unsafe flag instead of the safe path | "stop using the bypass flag" |
| unverified-claim | Stated done or a number without checking | "I don't see the comments" |
| missing-links | Evidence or links missing from a posted artifact | "add the latest link for review" |
| skipped-gate | Ran a local shortcut instead of the agreed gate, or skipped the gate | "rely on CI, not a local run" |
| publish-without-ask | Published or posted without an explicit yes | "never publish without my publish" |
| long-chat | Chat reply too long or too dense | "long replies are hard to read" |
| doc-gap | A doc missing a case the reader needs | "the mitigation was not covered" |
| tooling-lifecycle | Agent tooling or worker lifecycle misbehaved | "workers did not auto close" |
| other | Nothing above fits. Say why in the quote. | |
