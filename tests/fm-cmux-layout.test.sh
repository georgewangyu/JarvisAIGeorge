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
  local h="$TMP_ROOT/names" out
  mkdir -p "$h/config"
  out=$(layout "$h" 'fm_cmux_layout_home_name; echo; fm_cmux_layout_workers_label; echo; fm_cmux_layout_task_title fm-fix-login')
  [ "$out" = $'Jarvis\nJarvis: Workers\n◆ fix-login' ] || fail "primary names: got '$out'"
  echo ops > "$h/.fm-secondmate-home"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = "Friday ops" ] || fail "secondmate home name: got '$out'"
  printf 'Night shift\n' > "$h/config/cmux-home-name"
  out=$(layout "$h" 'fm_cmux_layout_workers_label')
  [ "$out" = "Night shift: Workers" ] || fail "config/cmux-home-name must win: got '$out'"
  pass "cmux layout: Jarvis, Friday <id>, and config/cmux-home-name"
}

test_buckets() {
  local h="$TMP_ROOT/buckets" out
  mkdir -p "$h"
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(layout "$h" 'for s in working parked done blocked failed paused unknown; do fm_cmux_layout_bucket "$s"; echo; done')
  [ "$out" = $'working\nworking\ndone\nneeds you\nneeds you\nneeds you\nworking' ] || fail "buckets: got '$out'"
  pass "cmux layout: crew states map to working, done, and needs you"
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

test_layout_is_opt_in
test_home_names_and_labels
test_buckets
test_sidebar_hook
