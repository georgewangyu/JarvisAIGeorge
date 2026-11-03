# cmux runtime backend

cmux is an experimental macOS GUI terminal backend.
It provides task workspaces and surfaces while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick cmux when you already use the app as your terminal and want task workspaces in its sidebar.
cmux is macOS-only, GUI-first, and unsuitable for a headless or SSH-only Firstmate session.

Prerequisites:

- cmux 0.64 or newer, installed from [cmux.com](https://cmux.com) or with `brew install --cask cmux`.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The CLI is not always installed on `PATH` with the app.
The adapter prefers `command -v cmux` and otherwise uses `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### Required socket access

cmux defaults to a control mode that rejects external shells, while Firstmate always controls it from an external process.
Open Settings > Automation and choose a viable Socket Control Mode before the first cmux-backed spawn.

| Setting | Value | Firstmate support | Security boundary |
| --- | --- | --- | --- |
| Off | `off` | No | The socket listener is disabled. |
| cmux processes only | `cmuxOnly` | No | Only descendants of the cmux app can connect. |
| Automation mode | `automation` | Yes, recommended | The owner-only 0600 socket admits processes of the current macOS user. |
| Password mode | `password` | Yes | The 0600 socket also requires an auth handshake. |
| Full open access | `allowAll` | Yes, not recommended | The 0666 socket admits every local user without authentication. |

Automation mode is the recommended same-user boundary.
`allowAll` can execute commands through a world-writable control socket and should be selected only as an explicit security tradeoff.

For Password mode, store the password as the first line of local gitignored `config/cmux-socket-password` or provide `CMUX_SOCKET_PASSWORD` in Firstmate's environment.
The adapter reads the file fresh from the effective config directory and does not overwrite an ambient password when the file is absent.
Configure the mode and password through the cmux UI rather than editing `cmux.json`; the app does not retain a hand-added password key, and socket-based reload cannot fix a socket that is rejecting the caller.

Select cmux with local `config/backend` containing `cmux`, `FM_BACKEND=cmux` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside cmux.
A spawn stops with an actionable setup message when the app, minimum version, `jq`, socket access, or password is unavailable.
The adapter may launch the app with `open -a cmux` only when the socket is down; it does not relaunch the app for access-denied or authentication errors.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing the cmux window forward.
Task workspace and surface creation use `focus=false`.

Verify setup by spawning a small task and confirming metadata contains `backend=cmux`, `cmux_workspace_id=`, and `cmux_surface_id=`.

## Runtime detection

`CMUX_WORKSPACE_ID` is the primary cmux runtime marker.
`CMUX_SOCKET_PATH` is not sufficient because operators may set it outside cmux.
Detection checks tmux first, then Herdr, then cmux, so a multiplexer nested inside cmux remains the active backend.

cmux's bundled Claude wrapper can remove every `CMUX_*` variable when its internal socket probe fails, including in Password mode.
On macOS only, detection therefore falls back first to `__CFBundleIdentifier=com.cmuxterm.app`, then to process ancestry reaching the running cmux app.
Those fallbacks are consulted only when neither tmux nor Herdr already won.
An environment-scrubbed or launchd-reparented process with no reliable marker is not auto-detected.

Auto-detection selects only the backend.
It never changes socket access or grants credentials.
The spawn refusal explains how to finish cmux setup or opt back into tmux.

## Task shape and metadata

Each task owns one cmux workspace with one surface.
The caller-facing label remains `fm-<id>`, while the visible workspace title is `fm-<home-label>-<id>`.
The home label is `firstmate` or `2ndmate-<id>` plus a stable short hash of the resolved Firstmate root.
cmux does not enforce title uniqueness, so create, recovery, list, and cleanup paths all validate this scoped title.
Relocating the Firstmate installation changes the hash and leaves old titles unmatched, consistent with recorded worktree paths also becoming stale.

```text
backend=cmux
window=<workspace-uuid>:<surface-uuid>
cmux_workspace_id=<workspace-uuid>
cmux_surface_id=<surface-uuid>
```

The UUID pair is the active endpoint authority within one app run.
Workspace UUIDs are not stable across an app relaunch, so recovery searches by the scoped title and then resolves the current surface id.

## Current operation and safety

A task workspace is created with exactly one create call.
cmux can acknowledge `new-workspace` before an immediate `workspace list` shows it, so the adapter waits, bounded, for the scoped label to resolve to a workspace with a surface.
A workspace that never becomes visible fails the spawn and is left in place for reconciliation; an acknowledged create is never repeated, in the plain or the grouped path.

A genuinely fresh surface returns an internal error from `read-screen` until something has been written.
Target readiness therefore uses the structural `list-panes` response instead of a content read.
Capture remains bounded and locally trimmed after `read-screen` becomes available.

`current_directory` follows a top-level shell `cd` but not the foreground subshell opened by `treehouse get`.
Spawn-time worktree discovery sends begin and end markers around `pwd`, captures the marked block, and joins wrapped path lines.

An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through cmux's submit machinery.
On the typed plane, literal send and Enter are separate calls.
Enter, Escape, and Ctrl-C are supported.
The composer verifier is a thin adapter: it captures a bounded plain-text tail and hands it with cmux's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape, including Claude's borderless `❯` row with its U+00A0 separator.
`read-screen` is plain text with no cursor primitive, so the shared classifier degrades a glyph row carrying trailing text to `unknown` rather than misreading a harness's own idle suggestion as unsent input.
An unstructured bare prompt is `unknown`, and a slash-popup placeholder remains `pending`, so only Enter is retried and text is never retyped.
cmux exposes no native generic agent busy signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup succeeds only when the task workspace is confirmed absent from every window afterwards.
A close response alone is not proof: cmux can answer with a confirmation request, with or without a nonzero exit, and leave the workspace open.
A confirmation request is retried once on that exact workspace with literal `--force` only when the client is the pinned `0.65.2 (113) [12023d89f]` build and the connected server replies `confirmation_required` with `retry with --force`. With an unverified client or reply, or when the workspace is still listed, cleanup refuses and keeps the task record. This build accepts `--force` even though `close-workspace --help` omits it; the 0.64 client does not implement the same confirmation protocol.
An unreachable app or an unreadable inventory is never read as a closed workspace.

A task workspace's last surface cannot be closed directly.
Cleanup owns the whole workspace and uses `close-workspace`.
cmux also refuses to remove the only workspace in a macOS window while returning a misleading success response.
When the task is last in its window, Firstmate creates one unfocused unnamed sibling workspace in that same window, closes the task workspace, and leaves the window with cmux's fresh default workspace.
The sibling never carries an `fm-` title and is ignored by recovery.
Creation starts only after a checked native `system.tree` RPC with `all_windows=true` proves its scoped label absent across the app.
Creation acknowledgements can precede tree visibility, so launch polls identity and default-surface readiness without repeating creation.
A grouped creation attempt that fails or remains unconfirmed never falls through to a second plain creation.

Cleanup uses the same native app-wide topology, checks that the task has a unique scoped label and exactly its recorded sole surface immediately before the first close and any confirmed retry, then polls bounded fresh native reads until neither its workspace ID nor label remains.
A running-process confirmation may be retried only for that same unique task identity and exact sole surface, under the pinned client/server capability rule above, after teardown's existing work-safety gates.
A failed or unreadable close retains metadata, including under teardown's `--force`; its backlog-close marker is published only after absence is proven.

The direct RPC is required because `cmux tree --all` can silently fall back to a sequence of window-scoped reads when the connected server lacks `system.tree`; the client version alone does not prove native support. The nested window, workspace, pane, and surface identities and declared counts must be internally consistent, or creation, close, and recovery-grade liveness fail closed. The server's native method gives a coherent view of live routable windows at read time; another UI actor can still change them after the reply.
A selected workspace that is not last closes normally; selection itself is not the trigger.
Firstmate does not attempt to close the macOS window because cmux's socket cannot close a window holding a live terminal.

Real tests share the captain's running app rather than creating an isolated cmux session.
`tests/cmux-test-safety.sh` permits cleanup only for an exact currently listed `fm-test-` workspace and never enumerates and closes unrelated workspaces or relaunches the app.

## Workers layout

Opt in per home with local `config/cmux-layout` containing `workers`, or `FM_CMUX_LAYOUT=workers` for one launch.
Without it the adapter behaves exactly as described above.
`bin/backends/cmux-layout.sh` owns the layout and `bin/fm-cmux-board.sh` owns the board.

```text
[pinned] JarvisAIGeorge                           manager tab, standalone
[pinned] JarvisAIGeorge: Workers · 1 working · 1 needs you
           (header runs the read-only board)
           ◆ fix-login                            one workspace per task
           ◆ add-tests                            orange = needs you, charcoal = done
```

- **Manager tab.** The first layout spawn records the caller's cmux workspace in `state/.cmux-manager-ws`, renames it to the home name, pins it, colors it, and keeps it right before its Workers group.
  The home name is `config/cmux-home-name` when present, else `JarvisAIGeorge` for a primary and `Friday <N> · <Charter>` for a secondmate home.
  N is the home's position in its local parent's `data/secondmates.md` (left out when the parent cannot be read), and Charter is `config/cmux-charter-name` or the secondmate id in title case.
- **Workers group.** One anchor-only cmux workspace group per home and window, named `<home>: Workers`, created under a home-local lock and an idempotency key.
  Task workspaces are created inside it with `--group`.
- **Board.** The group's generated header runs `bin/fm-cmux-board.sh`.
  Its `anchor_workspace_ref` resolves through the native tree to exactly one workspace UUID and surface before input is sent; ambiguous or absent anchors are left untouched.
  Every 10 seconds (`FM_CMUX_BOARD_INTERVAL`) it reads each task through `bin/fm-crew-state.sh` with forge reads off, redraws on change, renames the group with live counts, and colors worker tabs.
  It lists every task in the home and names each row's backend; only cmux tasks get tab colors.
  A state that is not verified stays `unknown` in its row, its count, and the group title, with the reason fm-crew-state gave, and is never counted as working.
  Codex is the common case: it has no verified live-state source for a terminal worker yet (its app-server cannot observe a pane worker and Firstmate-written project hooks do not fire; `bin/fm-busy-lib.sh` owns that verdict), so a Codex row reads `unknown` with that reason and only its finished turns are signalled.
  It never types into, wakes, or closes a worker.
  Because it reads the same pane and run-step state as supervision, it covers Codex and every other harness, including those that run no hooks.
- **Titles and identity.** A task tab is titled `◆ <task-id>`, and its scoped label `fm-<home-tag>-<id>` moves to the cmux workspace description.
  Every lookup accepts the title or the description, so home scoping, recovery, list, and cleanup keep working.
  Lifecycle lookups read every cmux window regardless of layout mode, so a teardown or peek run from another window still finds the task.
- **Sidebar state for Claude.** The core plugin's sidebar hook shows the session's state as pills on its own tab; see "Sidebar" below.
  Codex workers get no pills: their launches turn Codex hooks off, so the board's polling is their only tab state (colors and counts).
- **Wake and cleanup** are unchanged: the watcher wakes the manager on a worker's status event, and `bin/fm-teardown.sh` closes the worker tab only after its work has landed.

Gate evidence and what is untested (Codex, secondmates): `docs/verification/runtime-backends.md#cmux`.

## Sidebar

`plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh` runs on the session's hook events and shows its state as pills on its own cmux tab, top to bottom:

| Pill | Shows |
| --- | --- |
| `jarvis_activity` | `Ready` at start, `Working: <ask>` during a turn, `Needs approval` on a permission prompt, then `Done: <last step>`, `Waiting: <ask>` when the turn ends on a question, or `Error: <last step>` after a failed tool |
| `jarvis_tool` | the current tool (`Reading README.md`, `Checking git status`, `Running tests`), its past form once it finished, `<tool> failed`, or `Needs approval: <tool>` |
| `jarvis_subagents` | `Subagents: <n> running (<type>)` while subagents run |
| `jarvis_pr` | `PR #<n> <state>` for the session's branch, linked, from `gh pr view` |
| `jarvis_issue` | `Issue #<n>`, linked: the PR's first closing issue, else a branch named like `issue-<n>` or `<n>-...` |

- **Converging writes.** Each hook records the desired pill state and returns.
  A writer reconciles desired against sent under a per-surface lock and repeats while a newer event arrived, so hooks that fire in parallel converge on the latest state.
  A pill cmux refused is never marked sent and goes out on the next pass.
- **Ownership.** The first session on a tab owns it, identified by its client process (pid and start time).
  A different session with a live owner, such as a nested `claude -p` or a second client in a split pane, never drives the tab.
  `/clear` in the same client re-adopts it, and when the owner is gone the next start or prompt takes over.
- **Subagents** are tracked one file each and never move a finished turn back to Working.
  An entry whose stop never came expires after `JARVIS_SIDEBAR_SUBAGENT_TTL_MIN` minutes (120).
- **PR and issue lookups** run only in the writer, on start, stop, and after a `git` or `gh` command, at most once per branch every `JARVIS_SIDEBAR_REFS_SECS` seconds (120), and never on the default branch.
- **Safety.** It is a no-op outside cmux, never writes stdout, and always exits 0.
  cmux and `gh` only run in a detached writer with every call time-bounded (`JARVIS_SIDEBAR_CMUX_SECS`, `JARVIS_SIDEBAR_GH_SECS`), so a hook run returns well inside the 3-second Codex hook cap.
- **Controls.** `JARVIS_SIDEBAR=off` turns it off.
  State lives under `${XDG_STATE_HOME:-~/.local/state}/jarvis-ai-george/sidebar/<workspace>` (`JARVIS_SIDEBAR_STATE` overrides).
- **Known limits.** Claude Code has no "permission granted" event, so the approval pill stays until the next tool event.
  An Esc interrupt fires no Stop, so the activity line keeps `Working` until the next prompt.

Regression entry points: `tests/jarvis-sidebar.test.sh` and `tests/jarvis-sidebar-hook.test.sh`.

## Agent liveness

`fm_backend_cmux_agent_state` in `bin/backends/cmux.sh` is the recovery-grade probe `bin/fm-backend.sh` asks for.
It reads the surface's tty and foreground process groups from `cmux top --processes --json`, lists that tty with `ps`, and classifies each foreground process through `bin/fm-agent-process-lib.sh`, the same classifier tmux uses.
A verified harness reads `alive`, a foreground of shells only reads `dead`, a workspace or surface absent from a checked native all-window tree reads `missing`, and anything else (the app down, an incomplete tree, a restore command still running) reads `unreadable`.
Only `dead` and `missing` license recovery, so `bin/fm-control.sh` exit and relaunch and `bin/fm-spawn.sh --relaunch` now work on cmux.

## Reboot heal

cmux restores every tab after a reboot or an app relaunch and types a restore command into each one.
`bin/fm-cmux-reboot-heal.sh` runs on the locked session-start path and repairs what that leaves behind.

- **When.** The epoch is the boot time plus the cmux app pid, so an app relaunch counts too.
  The first run on a home only records it.
  A new epoch heals once the app has been up 45 seconds; while a tab cannot be read yet or an ask is open, a detached retry repeats the pass every minute for at most an hour, then the epoch is stamped.
- **Per task, in order:**
  1. Finds the tab again by its scoped label in every window and rewrites stale workspace and surface ids in the task record.
     Exactly one workspace may carry the label; with several, the task is reported as ambiguous, its record stays byte-identical, and neither tab is read, selected, or typed into.
  2. Selects a tab that cannot be read yet so cmux starts its terminal, then reselects the window's previous tab.
  3. Offers the screen to prompt hooks (below).
  4. Erases `cmux restore ...` text typed into a live agent's composer with Backspace and re-reads it; it never presses Enter there.
  5. Answers a folder-trust prompt only when it names the task's own recorded copy.
  6. Brings a bare shell back with `cmux restore --surface`, then, for a Claude task, `bin/fm-spawn.sh <id> --relaunch --resume`, which reopens the same conversation with a short resume note in place of the instructions.
     Every Claude launch pins `--session-id` and records `claude_session_id=`, so the resume is exact.
  7. Asks a worker brought back by cmux restore whose instructions mention a recurring loop to re-arm it, once per epoch.
- **Board.** With the Workers layout on, a board whose heartbeat (`state/.cmux-board-beat`, written only by this home's board) is stale and whose header holds only an idle shell is started again for this home.
- **Prompt hooks.** A local `config/cmux-heal-hooks.d/<name>.sh` (or the directory in `FM_CMUX_HEAL_HOOKS`) may define `fm_heal_hook_<name>_match <screen>`, `fm_heal_hook_<name>_answer <workspace> <surface> <screen>`, and `fm_heal_hook_<name>_ask`.
  A matched prompt is answered only when the hook's answer function succeeds; otherwise its ask is raised.
  No hooks ship; without one, a y/n prompt is a dialog that is left alone with an ask.
- **Asks** go to `state/cmux-heal-status.md` and one `cmux notify` per epoch; every action, ask, or leftover also prints one `BOOTSTRAP_INFO: cmux reboot heal:` line.
  A task it cannot heal is reported once and left to the ordinary dead-endpoint recovery.
- **Safety.** It never types into a tab running anything but a login shell, except the Backspace erase and a hook-approved answer, never kills or interrupts a live agent, and never answers "No, exit".
- **Controls.** `--dry-run` reports and changes nothing, `--force` (or `FM_CMUX_HEAL_FORCE=1`) runs a pass outside a new epoch, and `FM_CMUX_HEAL=off` turns it off.

The manager's own tab comes back through cmux's restore of its session, and its session start runs this pass.

## Active limits

- cmux is experimental, macOS-only, GUI-first, and requires the app running.
- Socket access requires a one-time manual Settings change.
- Secondmate spawns are unsupported until a per-home lifecycle design is verified, although the agent liveness probe they need now exists.
- There is no native busy or push-event signal.
- A target can disappear after structural readiness and before the operation.
- The only-workspace cleanup path leaves a fresh default workspace and cannot close the window.
- Label lookup and recovery use the native app-wide tree in every layout mode.
- Workspace ids do not survive app relaunch and are never recovery authority.

## Regression entry points

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) records the active source and live evidence, including socket modes and last-in-window cleanup.
