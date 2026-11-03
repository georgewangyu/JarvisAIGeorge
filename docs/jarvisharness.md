# JarvisHarness provenance and adaptation plan

JarvisHarness is George Wang's public fork of [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate).
The GitHub fork inherits FirstMate's prior Git history, MIT license, and upstream authorship.
The first JarvisHarness-specific commit is intentionally small: it records the fork baseline and the public adaptation contract before any product rewrite.

## Public engine boundary

JarvisHarness is intended to be a reusable public engine for a single human operator who wants supervised agent workers without embedding private controller policy in the engine.
George's private controller name, private agent definitions, local paths, personal state, credentials, and home-specific operating records are not required by the public engine and should stay in private configuration or a private adoption layer.

User-specific behavior should be supplied through explicit configuration, documented examples with placeholders, or separately maintained private files.
A public JarvisHarness commit must not rely on George-private repositories or absolute local paths.

## Runtime direction

JarvisHarness is expected to adapt FirstMate's runtime ideas rather than copy them blindly.
The intended defaults are:

- Herdr is the preferred default runtime direction for visible worker sessions.
- cmux may be supported as an optional adapter, but a task must use one runtime adapter at a time; Herdr and cmux state must not adopt, repair, or clean up each other's tasks.
- Ordinary workers come before durable managers.
  A persistent manager should exist only after repeated, observed coordination need proves that a stable workstream owner is useful.
- Specialist Agent Packs should be user-configurable modules, not hardcoded private roles.
- No-worktree shared-checkout operation is a JarvisHarness goal for environments where the operator wants a single canonical checkout and uses temporary copied sandboxes, fixtures, or runtime isolation instead of Git worktrees.

These are roadmap constraints, not claims that the current inherited code already implements them.
The current codebase still reflects FirstMate behavior unless a later JarvisHarness commit changes it with tests and documentation.

## Upstream sync contract

The fork starts from the baseline recorded in [`JARVISHARNESS_UPSTREAM_BASELINE.json`](../JARVISHARNESS_UPSTREAM_BASELINE.json).
Future FirstMate sync is review-driven and commit-pinned.
JarvisHarness should inspect upstream changes in a copied temporary sandbox or another non-worktree isolation mechanism, classify each reviewed change, and port only the behavior that fits this fork's public boundary and runtime goals.

Do not auto-merge unreviewed upstream `main`.
Do not create side branches or Git worktrees for sync review.
Do not claim selective sync is implemented until the fork has real inventory, review, validation, and release mechanics.

## User-facing voice (decided 2026-11-02)

Jarvis drops FirstMate's "captain" persona in what the user sees: chat follows `config/user-address` (setup asks "What should Jarvis call you?", default plain "you"), the no-op reply is `Nothing to report.`, and the bearings board says "Your call".
Internal identifiers and the FirstMate vocabulary in the contract, docs and skills (captain as the word for the user, crewmate, secondmate, `captains_call`, `fm-captain-hold.sh`) stay as they are, so upstream FirstMate syncs stay cheap.
`AGENTS.md` says once that "captain" there means the user and is not a form of address.


## CI trim (decided 2026-11-02)

The inherited `CI` workflow keeps the jobs and tests for what Jarvis runs: Claude Code and Codex workers on cmux or tmux, and the shared spawn, teardown, supervision, watcher, backlog, secondmate and PR code.
`bin/fm-test-run.sh` owns the dropped list (`jarvis_dropped_reason`), and `bin/fm-test-run.sh --list-dropped` prints every skipped suite with its reason.
The files stay in `tests/` so a FirstMate sync applies cleanly; a sync that adds a suite for a dropped tool should extend that list rather than delete the file.

| Dropped | Reason |
|---|---|
| Pi suites (`fm-pi-*`, `fm-calm-pi-extension`, Pi plus Herdr returns) | Pi harness: not used by Jarvis |
| `fm-grok-*` | grok harness: not used by Jarvis |
| `fm-kimi-*` | kimi harness: not used by Jarvis |
| `fm-muse-*` | muse harness: not used by Jarvis |
| `fm-omp-*` | omp harness: not used by Jarvis |
| `fm-agy-*`, `fm-send-agy-confirm` | agy harness: not used by Jarvis |
| `fm-rovo-*` | rovo harness: not used by Jarvis |
| `fm-gemini-*` | gemini harness: not used by Jarvis |
| `fm-cursor-harness`, `fm-cursor-primary*` | Cursor harness: not used by Jarvis |
| `fm-opencode-*` | opencode harness: not used by Jarvis |
| `fm-backend-zellij*` | zellij backend: Jarvis uses cmux or tmux |
| `fm-backend-orca*` | orca backend: Jarvis uses cmux or tmux |
| The `tests-herdr` job and the `real-herdr-gated` family, plus the live Herdr e2e suites | real Herdr lane: Jarvis uses cmux or tmux; the portable Herdr unit tests (`fm-backend-herdr`, `fm-herdr-lab`, `fm-herdr-session-cleanup`, `fm-remote-herdr-guard`) still run because shared backend code calls them |
| Treehouse lease checks in shared-checkout mode | not dropped: `fm_backend_required_tools` asks for treehouse only in worktree mode, so the bootstrap cases now pin worktree mode instead |

Live opt-in suites for Claude and Codex stay; they skip without their live-capability gate as before.
