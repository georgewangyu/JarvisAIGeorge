#!/usr/bin/env bash
# tests/jarvis-setup.test.sh - unit tests for bin/jarvis-setup.sh: the
# first-run hook speaks only when setup is incomplete, the backend choice
# writes the right config, plugin detection accepts the trust-loaded cache,
# and the update check stays quiet when turned off. No network, no installs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-setup-tests)
SETUP="$ROOT/bin/jarvis-setup.sh"

run() {  # <home> <claude-dir> <args...>
  local h=$1 c=$2; shift 2
  FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" "$@"
}

test_backend_choice() {
  local h="$TMP_ROOT/backend" c="$TMP_ROOT/backend-claude"
  mkdir -p "$h" "$c"
  run "$h" "$c" backend cmux >/dev/null || fail "backend cmux must succeed"
  [ "$(cat "$h/config/backend")" = cmux ] || fail "backend cmux must write config/backend"
  [ "$(cat "$h/config/cmux-layout")" = workers ] || fail "backend cmux must turn on the Workers layout"
  run "$h" "$c" backend tmux >/dev/null
  [ "$(cat "$h/config/backend")" = tmux ] && [ ! -e "$h/config/cmux-layout" ] || fail "backend tmux must drop the cmux layout"
  run "$h" "$c" backend auto >/dev/null
  [ ! -e "$h/config/backend" ] && [ "$(cat "$h/config/jarvis-backend")" = auto ] || fail "backend auto must leave detection to the runtime and record the choice"
  run "$h" "$c" backend bogus >/dev/null 2>&1 && fail "an unknown backend must be refused"
  pass "jarvis-setup: backend cmux, tmux and auto write the expected config"
}

test_detect_names_gaps() {
  local h="$TMP_ROOT/detect" c="$TMP_ROOT/detect-claude" out
  mkdir -p "$h" "$c"
  out=$(run "$h" "$c" detect)
  printf '%s' "$out" | grep -q '^JARVIS_FIRST_RUN: ' || fail "an empty home must print the first-run line: '$out'"
  printf '%s' "$out" | grep -q 'backend choice' || fail "first-run line must name the backend choice"
  printf '%s' "$out" | grep -q 'plugins: jarvis-ai-george' || fail "first-run line must name the missing core plugin"
  printf '%s' "$out" | grep -q 'docs/install.md' || fail "first-run line must point at docs/install.md"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "detect prints one line"
  run "$h" "$c" backend tmux >/dev/null
  mkdir -p "$c/plugins/cache/jarvis-ai-george/jarvis-ai-george/0.2.0"
  run "$h" "$c" extensions none >/dev/null
  out=$(run "$h" "$c" detect)
  printf '%s' "$out" | grep -q 'backend choice\|plugins:\|extensions not chosen' \
    && fail "recorded choices and a trust-loaded plugin must not be reported: '$out'"
  pass "jarvis-setup: detect names each gap once and accepts the trust-loaded plugin cache"
}

test_update_check_off() {
  local h="$TMP_ROOT/update" c="$TMP_ROOT/update-claude" out
  mkdir -p "$h/config" "$c"
  echo off > "$h/config/update-check"
  out=$(run "$h" "$c" update-check)
  [ -z "$out" ] || fail "config/update-check=off must silence the check: '$out'"
  pass "jarvis-setup: update check is off with config/update-check"
}

test_backend_choice
test_detect_names_gaps
test_update_check_off
