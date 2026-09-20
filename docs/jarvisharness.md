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
