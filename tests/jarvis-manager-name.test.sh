#!/usr/bin/env bash
# tests/jarvis-manager-name.test.sh - the manager is JarvisAIGeorge by default in
# every harness and overridable in config/manager-name, and the cmux manager tab
# is named at session start for Claude Code and Codex alike, not only at the
# first worker spawn. No real cmux, Claude or Codex: stub CLIs and fake
# lower-level cmux functions. The live Codex tab rename is for a personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-manager-name-tests)

layout() {  # <home> <snippet>
  FM_HOME="$1" FM_ROOT="$ROOT" bash -c '. "$0/bin/backends/cmux.sh"; eval "$1"' "$ROOT" "$2"
}

test_default_and_override_names() {
  local h="$TMP_ROOT/names" out
  mkdir -p "$h/config"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = JarvisAIGeorge ] || fail "default tab name must be JarvisAIGeorge, got '$out'"
  FM_HOME="$h" "$ROOT/bin/jarvis-setup.sh" manager-name Ada >/dev/null || fail "manager-name must succeed"
  [ "$(cat "$h/config/manager-name")" = Ada ] || fail "manager-name must write config/manager-name"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = Ada ] || fail "config/manager-name must name the tab, got '$out'"
  printf 'Night shift\n' > "$h/config/cmux-home-name"
  out=$(layout "$h" 'fm_cmux_layout_home_name')
  [ "$out" = "Night shift" ] || fail "config/cmux-home-name must still win for the tab, got '$out'"
  FM_HOME="$h" "$ROOT/bin/jarvis-setup.sh" status 2>/dev/null | grep -qx 'ok: manager name Ada (config/manager-name)' \
    || fail "status must show the manager name"
  FM_HOME="$h" "$ROOT/bin/jarvis-setup.sh" manager-name default >/dev/null
  [ ! -e "$h/config/manager-name" ] || fail "manager-name default must remove the override"
  pass "manager name: JarvisAIGeorge by default, config/manager-name overrides chat and tab, cmux-home-name still wins for the tab"
}

test_role_and_agents_use_the_name() {
  local f
  for f in "$ROOT/plugins/jarvis-ai-george/skills/role-jarvis/SKILL.md" \
    "$ROOT/plugins/jarvis-ai-george/agents/jarvis-ai-george.md" "$ROOT/.claude/agents/jarvis-ai-george.md"; do
    grep -qF 'You are JarvisAIGeorge' "$f" || fail "$f must name the manager JarvisAIGeorge"
    grep -qF 'config/manager-name' "$f" || fail "$f must point at the config/manager-name override"
    grep -qE 'You are Jarvis[,.]' "$f" && fail "$f still calls the manager plain Jarvis"
  done
  grep -qF '**JarvisAIGeorge**' "$ROOT/AGENTS.md" || fail "the AGENTS.md manager section must name JarvisAIGeorge"
  pass "manager name: role-jarvis, the plugin and project agents, and AGENTS.md all say JarvisAIGeorge"
}

test_claim_names_the_tab_at_session_start() {
  local h="$TMP_ROOT/claim" log
  mkdir -p "$h/config" "$h/state"
  echo workers > "$h/config/cmux-layout"
  log="$TMP_ROOT/claim.log"
  : > "$log"
  CMUX_WORKSPACE_ID=ws-mgr FM_HOME="$h" FM_ROOT="$ROOT" LOG="$log" bash -c '
    . "$0/bin/backends/cmux.sh"
    fm_cmux_layout_window_of() { printf window:1; }
    fm_cmux_layout_find_group() { printf ""; }
    fm_backend_cmux_cli() { printf "%s\n" "$*" >> "$LOG"; }
    fm_cmux_layout_claim_manager' "$ROOT"
  grep -q -- '--workspace ws-mgr --window window:1 --action rename --title JarvisAIGeorge' "$log" \
    || fail "session start must rename the manager tab: $(cat "$log")"
  grep -q -- '--action pin' "$log" || fail "session start must pin the manager tab"
  grep -q 'workspace-group create' "$log" && fail "session start must not create the Workers group"
  [ "$(cat "$h/state/.cmux-manager-ws")" = ws-mgr ] || fail "the manager workspace must be recorded"
  : > "$log"
  echo off > "$h/config/cmux-layout"
  CMUX_WORKSPACE_ID=ws-mgr FM_HOME="$h" FM_ROOT="$ROOT" LOG="$log" bash -c '
    . "$0/bin/backends/cmux.sh"
    fm_backend_cmux_cli() { printf "%s\n" "$*" >> "$LOG"; }
    fm_cmux_layout_claim_manager' "$ROOT"
  [ ! -s "$log" ] || fail "with the layout off nothing may change: $(cat "$log")"
  pass "manager name: the layout names, pins and colors the manager tab at session start without creating the group"
}

test_hooks_and_launcher_run_the_claim() {
  local h="$TMP_ROOT/launch" bin="$TMP_ROOT/launch-bin" outer="$TMP_ROOT/launch-outer" t
  command -v jq >/dev/null 2>&1 || { pass "manager name: hook wiring (skipped, no jq)"; return; }
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("fm-cmux-claim-manager.sh"))' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "the Claude SessionStart hooks must run the claim"
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("fm-cmux-claim-manager.sh"))' "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "the Codex SessionStart hooks must run the claim"
  mkdir -p "$h/config" "$h/state" "$bin" "$outer"
  echo workers > "$h/config/cmux-layout"
  for t in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/$t"
    chmod +x "$bin/$t"
  done
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/cmux"
  chmod +x "$bin/cmux"
  for t in claude codex; do
    rm -f "$h/state/.cmux-manager-ws"
    (cd "$outer" && PATH="$bin:$PATH" CMUX_WORKSPACE_ID="ws-$t" FM_HOME="$h" "$ROOT/bin/jarvis-launch" --$t) \
      || fail "jarvis-launch --$t must exec its tool"
    [ "$(cat "$h/state/.cmux-manager-ws" 2>/dev/null)" = "ws-$t" ] \
      || fail "jarvis-launch --$t must claim the manager tab before starting the tool"
  done
  pass "manager name: the Claude and Codex SessionStart hooks and jarvis-launch both claim the manager tab"
}

test_default_and_override_names
test_role_and_agents_use_the_name
test_claim_names_the_tab_at_session_start
test_hooks_and_launcher_run_the_claim
