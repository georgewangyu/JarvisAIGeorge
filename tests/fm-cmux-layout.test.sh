#!/usr/bin/env bash
# tests/fm-cmux-layout.test.sh - unit tests for the opt-in cmux Workers layout
# (bin/backends/cmux-layout.sh) and the Claude sidebar hook
# (plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh). No real cmux: the hook
# test uses a logging fake `cmux` on PATH. Live evidence: docs/cmux-backend.md
# "Workers layout".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-cmux-layout-tests)

layout() {  # <home> <snippet>
  FM_HOME="$1" FM_ROOT="$ROOT" bash -c '. "$0/bin/backends/cmux.sh"; eval "$1"' "$ROOT" "$2"
}

test_layout_is_opt_in() {
  local h="$TMP_ROOT/optin"
  mkdir -p "$h/config"
  layout "$h" 'fm_cmux_layout_enabled' && fail "layout must be off without config/cmux-layout"
  echo workers > "$h/config/cmux-layout"
  layout "$h" 'fm_cmux_layout_enabled' || fail "config/cmux-layout=workers must enable the layout"
  echo off > "$h/config/cmux-layout"
  FM_CMUX_LAYOUT=workers layout "$h" 'fm_cmux_layout_enabled' || fail "FM_CMUX_LAYOUT=workers must enable it for one launch"
  pass "cmux layout: opt-in by config/cmux-layout or FM_CMUX_LAYOUT"
}

test_home_names_and_labels() {
  local h="$TMP_ROOT/names" p="$TMP_ROOT/names-parent" out
  mkdir -p "$h/config" "$p/data"
  out=$(layout "$h" 'fm_cmux_layout_home_name; echo; fm_cmux_layout_workers_label; echo; fm_cmux_layout_task_title fm-fix-login')
  [ "$out" = $'JarvisAIGeorge\nJarvisAIGeorge: Workers\n◆ fix-login' ] || fail "primary names: got '$out'"
  echo custodian-cr > "$h/.fm-secondmate-home"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = "Friday · Custodian Cr" ] || fail "secondmate without a readable parent: got '$out'"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$p" > "$h/.fm-secondmate-parent"
  printf '%s\n' '- ops - Ops work (home: /x; scope: ops; projects: none; added 2026-11-01)' \
    '- custodian-cr - CR work (home: /y; scope: cr; projects: none; added 2026-11-02)' > "$p/data/secondmates.md"
  out=$(layout "$h" 'fm_cmux_layout_home_name; echo; fm_cmux_layout_workers_label')
  [ "$out" = $'Friday 2 · Custodian Cr\nFriday 2 · Custodian Cr: Workers' ] || fail "secondmate names: got '$out'"
  echo Custodian > "$h/config/cmux-charter-name"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = "Friday 2 · Custodian" ] || fail "config/cmux-charter-name must win: got '$out'"
  printf 'Night shift\n' > "$h/config/cmux-home-name"
  out=$(layout "$h" 'fm_cmux_layout_workers_label')
  [ "$out" = "Night shift: Workers" ] || fail "config/cmux-home-name must win: got '$out'"
  pass "cmux layout: JarvisAIGeorge, Friday <N> · <Charter>, and both config overrides"
}

test_buckets() {
  local h="$TMP_ROOT/buckets" out
  mkdir -p "$h"
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(layout "$h" 'for s in working parked done blocked failed paused unknown; do fm_cmux_layout_bucket "$s"; echo; done')
  [ "$out" = $'working\nworking\ndone\nneeds you\nneeds you\nneeds you\nunknown' ] || fail "buckets: got '$out'"
  pass "cmux layout: crew states map to working, done, needs you, and unknown"
}

test_sidebar_hook() {
  local d="$TMP_ROOT/hook" hook="$ROOT/plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh"
  mkdir -p "$d/bin" "$d/tmp"
  cat > "$d/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOOK_LOG"
SH
  chmod +x "$d/bin/cmux"
  run_hook() { printf '%s' "$1" | PATH="$d/bin:$PATH" TMPDIR="$d/tmp" HOOK_LOG="$d/log" CMUX_WORKSPACE_ID="${2-ws-1}" bash "$hook"; }
  run_hook '{"hook_event_name":"PreToolUse"}'
  run_hook '{"hook_event_name":"PreToolUse"}'
  run_hook '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'
  run_hook '{"hook_event_name":"PermissionRequest"}'
  run_hook '{"hook_event_name":"Stop"}'
  run_hook '{"hook_event_name":"SessionEnd"}'
  run_hook '{"hook_event_name":"PreToolUse"}' ''
  [ "$(grep -c 'set-status jarvis working' "$d/log")" = 1 ] || fail "working must be written once (change-only)"
  grep -q 'set-status jarvis needs you' "$d/log" || fail "permission request must show needs you"
  grep -q 'set-status jarvis done' "$d/log" || fail "Stop must show done"
  grep -q 'clear-status jarvis' "$d/log" || fail "SessionEnd must clear the pill"
  [ "$(wc -l < "$d/log" | tr -d ' ')" = 4 ] || fail "idle reminder and non-cmux runs must write nothing: $(cat "$d/log")"
  pass "jarvis-sidebar hook: change-only pill, idle reminders ignored, no-op outside cmux"
}

test_board_keeps_unknown_and_names_backend() {
  local h="$TMP_ROOT/board" out stub="$TMP_ROOT/board-crew-state.sh"
  mkdir -p "$h/state" "$h/config"
  printf 'backend=cmux\ncmux_workspace_id=W1\nkind=ship\n' > "$h/state/a.meta"
  printf 'backend=cmux\ncmux_workspace_id=W2\nkind=ship\n' > "$h/state/b.meta"
  printf 'backend=tmux\nkind=ship\n' > "$h/state/c.meta"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case "$1" in
  a) echo 'state: working · source: pane · harness busy' ;;
  b) echo 'state: unknown · source: pane · harness state unavailable (unknown kimi-unverified)' ;;
  c) echo 'state: done · source: status-log · done' ;;
esac
SH
  chmod +x "$stub"
  out=$(FM_HOME="$h" FM_CREW_STATE_BIN="$stub" bash "$ROOT/bin/fm-cmux-board.sh" --once)
  printf '%s\n' "$out" | sed -n 2p | grep -qx '  1 working · 1 unknown · 1 done' || fail "summary must count unknown separately: $out"
  printf '%s\n' "$out" | grep -Eq '^  unknown +b +cmux +unknown$' || fail "unknown row must stay unknown with its backend: $out"
  printf '%s\n' "$out" | grep -q 'why: Kimi has no verified live-state source' || fail "unknown row must carry its reason: $out"
  printf '%s\n' "$out" | grep -Eq '^  done +c +tmux +done$' || fail "a row from another backend must name it: $out"
  pass "cmux board: unknown stays unknown in rows and counts; rows name their backend"
}

# make_group_fake <dir>: a fake cmux holding one window, a manager workspace,
# and one Workers group whose name lives in <dir>/group-name.
make_group_fake() {
  local d=$1
  mkdir -p "$d/bin"
  echo 'JarvisAIGeorge: Workers' > "$d/group-name"
  cat > "$d/bin/cmux" <<'SH'
#!/usr/bin/env bash
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/log"
case "$1" in
  list-windows) echo '[{"id":"WIN"}]' ;;
  workspace) echo '{"workspaces":[{"id":"MGR","title":"JarvisAIGeorge"}]}' ;;
  workspace-group)
    case "$2" in
      list) jq -n --arg n "$(cat "$D/group-name")" '{groups:[{ref:"workspace_group:1",name:$n,anchor_workspace_ref:"workspace:2"}]}' ;;
      rename) [ -f "$D/rename-fails" ] && exit 1; shift 2; while [ $# -gt 0 ]; do [ "$1" = --name ] && printf '%s\n' "$2" > "$D/group-name"; shift; done ;;
    esac ;;
  *) : ;;
esac
SH
  chmod +x "$d/bin/cmux"
}

test_board_group_summary() {
  local d="$TMP_ROOT/group" h stub
  h="$d/home"; stub="$d/stub.sh"
  mkdir -p "$h/state" "$h/config"
  make_group_fake "$d"
  echo workers > "$h/config/cmux-layout"
  echo MGR > "$h/state/.cmux-manager-ws"
  printf 'backend=cmux\ncmux_workspace_id=W1\nkind=ship\n' > "$h/state/a.meta"
  printf 'backend=cmux\ncmux_workspace_id=W2\nkind=ship\n' > "$h/state/b.meta"
  # shellcheck disable=SC2016 # the stub's own $1
  printf '#!/usr/bin/env bash\ncase "$1" in a) echo "state: working · source: pane · x" ;; *) echo "state: unknown · source: pane · y" ;; esac\n' > "$stub"
  chmod +x "$stub"
  PATH="$d/bin:$PATH" FAKE_DIR="$d" FM_HOME="$h" FM_CREW_STATE_BIN="$stub" FM_CMUX_BOARD_INTERVAL=0 \
    bash "$ROOT/bin/fm-cmux-board.sh" --passes 1 >/dev/null
  [ "$(cat "$d/group-name")" = 'JarvisAIGeorge: Workers · 1 working · 1 unknown' ] || fail "group summary: got '$(cat "$d/group-name")'"
  pass "cmux board: the group title carries the same counts, unknown included"
}

test_board_title_resets_after_last_task() {
  local d="$TMP_ROOT/last" h stub out
  h="$d/home"; stub="$d/stub.sh"
  mkdir -p "$h/state" "$h/config"
  make_group_fake "$d"
  echo workers > "$h/config/cmux-layout"
  echo MGR > "$h/state/.cmux-manager-ws"
  printf 'backend=cmux\ncmux_workspace_id=W1\nkind=ship\n' > "$h/state/a.meta"
  printf '#!/usr/bin/env bash\necho "state: unknown · source: pane · y"\n' > "$stub"
  chmod +x "$stub"
  board() { PATH="$d/bin:$PATH" FAKE_DIR="$d" FM_HOME="$h" FM_CREW_STATE_BIN="$stub" FM_CMUX_BOARD_INTERVAL=0 bash "$ROOT/bin/fm-cmux-board.sh" --passes 1; }
  board >/dev/null
  [ "$(cat "$d/group-name")" = 'JarvisAIGeorge: Workers · 1 unknown' ] || fail "one unknown task: got '$(cat "$d/group-name")'"
  rm -f "$h/state/a.meta"
  out=$(board)
  [ "$(cat "$d/group-name")" = 'JarvisAIGeorge: Workers' ] || fail "last task removed must reset the title: got '$(cat "$d/group-name")'"
  printf '%s' "$out" | grep -q 'no workers' || fail "board must show no workers: $out"
  printf '%s' "$out" | grep -q 'title sync' && fail "a successful reset must not report a sync problem: $out"
  : > "$d/rename-fails"
  printf 'backend=cmux\ncmux_workspace_id=W1\nkind=ship\n' > "$h/state/a.meta"
  out=$(board)
  printf '%s' "$out" | grep -q "title sync: group title still reads 'JarvisAIGeorge: Workers'" || fail "a failed rename must be shown: $out"
  ! grep -Eq 'close|send' "$d/log" || fail "title sync must never close or type into a worker"
  pass "cmux board: the title resets after the last task, and a failed rename is shown and retried"
}

test_board_explains_codex_unknown() {
  local h="$TMP_ROOT/codex" out stub="$TMP_ROOT/codex-crew-state.sh"
  mkdir -p "$h/state" "$h/config"
  printf 'backend=cmux\ncmux_workspace_id=W1\nkind=ship\nharness=codex\n' > "$h/state/cx.meta"
  printf 'backend=cmux\ncmux_workspace_id=W2\nkind=ship\n' > "$h/state/odd.meta"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
case "$1" in
  cx) echo 'state: unknown · source: pane · harness state unavailable (unknown codex-unverified)' ;;
  *) echo 'state: unknown · source: none · no task metadata' ;;
esac
SH
  chmod +x "$stub"
  out=$(FM_HOME="$h" FM_CREW_STATE_BIN="$stub" bash "$ROOT/bin/fm-cmux-board.sh" --once)
  printf '%s\n' "$out" | sed -n 2p | grep -qx '  2 unknown' || fail "Codex must stay unknown, never working: $out"
  printf '%s\n' "$out" | grep -q 'why: Codex gives no verified live state' || fail "Codex row must explain the missing source: $out"
  printf '%s\n' "$out" | grep -q 'why: no task metadata' || fail "other unknowns keep their own detail: $out"
  pass "cmux board: an unverified Codex worker shows unknown with the missing-capability reason"
}

test_layout_is_opt_in
test_board_explains_codex_unknown
test_board_title_resets_after_last_task
test_board_keeps_unknown_and_names_backend
test_board_group_summary
test_home_names_and_labels
test_buckets
test_sidebar_hook
