#!/usr/bin/env bash
# tests/jarvis-setup.test.sh - unit tests for bin/jarvis-setup.sh: the
# first-run hook speaks only when setup is incomplete, the backend choice
# writes the right config, plugin detection accepts the trust-loaded cache,
# the update check stays quiet when turned off, and the Claude and Codex
# install commands and installed checks are right (stub CLIs). No network, no installs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-setup-tests)
SETUP="$ROOT/bin/jarvis-setup.sh"

run() {  # <home> <claude-dir> <args...>
  local h=$1 c=$2; shift 2
  JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" "$@"
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

# A stub plugin CLI on PATH: records every call, lists no marketplaces.
make_stub() {  # <dir> <name>
  mkdir -p "$1"
  cat > "$1/$2" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/$2.calls"
exit 0
STUB
  chmod +x "$1/$2"
}

test_codex_install_commands() {
  local h="$TMP_ROOT/codex" x="$TMP_ROOT/codex-home" bin="$TMP_ROOT/codex-bin" out calls
  mkdir -p "$h" "$x"
  make_stub "$bin" codex
  out=$(PATH="$bin:$PATH" JARVIS_HARNESS=codex CODEX_HOME="$x" FM_HOME="$h" "$SETUP" extensions george-coding-agent) \
    || fail "codex extensions install must succeed: '$out'"
  calls=$(cat "$bin/codex.calls")
  printf '%s\n' "$calls" | grep -qx 'plugin marketplace list' || fail "codex: must check the marketplace list first: '$calls'"
  printf '%s\n' "$calls" | grep -q '^plugin marketplace add ' || fail "codex: must add the marketplace when missing: '$calls'"
  printf '%s\n' "$calls" | grep -qx 'plugin add george-coding-agent@jarvis-ai-george' \
    || fail "codex: must install with codex plugin add <plugin>@jarvis-ai-george: '$calls'"
  printf '%s\n' "$calls" | grep -q 'plugin install' && fail "codex: must not use the Claude install verb: '$calls'"
  grep -qx george-coding-agent "$h/config/extensions" || fail "codex: the choice must be recorded"
  : > "$bin/codex.calls"
  PATH="$bin:$PATH" JARVIS_HARNESS=codex CODEX_HOME="$x" FM_HOME="$h" "$SETUP" plugins >/dev/null || fail "codex plugins must succeed"
  grep -qx 'plugin add jarvis-ai-george@jarvis-ai-george' "$bin/codex.calls" || fail "codex: plugins must add the core plugin"
  [ "$(PATH="$bin:$PATH" JARVIS_HARNESS=codex "$SETUP" harness)" = codex ] || fail "JARVIS_HARNESS=codex must select codex"
  pass "jarvis-setup: under Codex, plugins and extensions run codex plugin marketplace add and codex plugin add"
}

test_claude_install_commands() {
  local h="$TMP_ROOT/claude-cli" c="$TMP_ROOT/claude-cli-dir" bin="$TMP_ROOT/claude-bin"
  mkdir -p "$h" "$c"
  make_stub "$bin" claude
  PATH="$bin:$PATH" JARVIS_HARNESS=claude CLAUDE_CONFIG_DIR="$c" FM_HOME="$h" "$SETUP" plugins >/dev/null || fail "claude plugins must succeed"
  grep -qx 'plugin install jarvis-ai-george@jarvis-ai-george --scope user' "$bin/claude.calls" \
    || fail "claude: plugins must keep claude plugin install --scope user: '$(cat "$bin/claude.calls")'"
  pass "jarvis-setup: under Claude Code, plugins still runs claude plugin install"
}

test_installed_from_either_marketplace() {
  local h="$TMP_ROOT/either" c="$TMP_ROOT/either-claude" x="$TMP_ROOT/either-codex" out
  mkdir -p "$h/config" "$c/plugins" "$x/plugins/cache/george-coding-agent/george-coding-agent/0.2.0" \
    "$x/plugins/cache/jarvis-ai-george/jarvis-ai-george/local"
  echo george-coding-agent > "$h/config/extensions"
  printf '{"plugins":{"jarvis-ai-george@jarvis-ai-george":[{}],"george-coding-agent@george-coding-agent":[{}]}}\n' \
    > "$c/plugins/installed_plugins.json"
  out=$(JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" status)
  printf '%s' "$out" | grep -q '^ok: extensions george-coding-agent' \
    || fail "claude: an extension installed from its own marketplace must count as installed: '$out'"
  printf '%s' "$out" | grep -q '^ok: plugins jarvis-ai-george' || fail "claude: core plugin must count as installed"
  out=$(JARVIS_HARNESS=codex FM_HOME="$h" CODEX_HOME="$x" "$SETUP" status)
  printf '%s' "$out" | grep -q '^ok: harness codex' || fail "codex: status must name the harness: '$out'"
  printf '%s' "$out" | grep -q '^ok: extensions george-coding-agent' \
    || fail "codex: the plugin cache under CODEX_HOME must count as installed: '$out'"
  printf '%s' "$out" | grep -q '^ok: plugins jarvis-ai-george' || fail "codex: core plugin cache must count as installed"
  out=$(JARVIS_HARNESS=codex FM_HOME="$h" CODEX_HOME="$TMP_ROOT/empty-codex" "$SETUP" status)
  printf '%s' "$out" | grep -q 'MISSING plugins jarvis-ai-george' || fail "codex: a Claude install must not count for Codex: '$out'"
  pass "jarvis-setup: a plugin counts as installed from either marketplace, per tool"
}

test_codex_sessionstart_hook() {
  local cmd h="$TMP_ROOT/codex-hook" out
  command -v jq >/dev/null 2>&1 || { pass "jarvis-setup: codex SessionStart hook (skipped, no jq)"; return; }
  mkdir -p "$h"
  cmd=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("jarvis-setup.sh"))][0] // empty' "$ROOT/.codex/hooks.json")
  [ -n "$cmd" ] || fail ".codex/hooks.json must run bin/jarvis-setup.sh detect at SessionStart"
  out=$(printf '%s' '{"hook_event_name":"SessionStart"}' \
    | (cd "$ROOT" && FM_HOME="$h" CODEX_HOME="$TMP_ROOT/codex-hook-home" bash -c "$cmd"))
  printf '%s' "$out" | grep -q '^JARVIS_FIRST_RUN: ' || fail "the codex SessionStart hook must print the first-run line: '$out'"
  printf '%s' "$out" | grep -q 'plugins: jarvis-ai-george' || fail "under Codex the hook must read the Codex plugin cache: '$out'"
  pass "jarvis-setup: the tracked Codex SessionStart hook runs detect for the Codex harness"
}

test_address_and_shortcut() {
  local h="$TMP_ROOT/sc" c="$TMP_ROOT/sc-claude" fake="$TMP_ROOT/sc-home" out before
  mkdir -p "$h" "$c" "$fake/work"
  out=$(run "$h" "$c" detect)
  printf '%s' "$out" | grep -q 'how to address the user not asked' || fail "detect must ask how to address the user: '$out'"
  printf '%s' "$out" | grep -q 'launch shortcut not offered' || fail "detect must offer the launch shortcut: '$out'"
  run "$h" "$c" address none >/dev/null
  [ "$(cat "$h/config/user-address")" = none ] || fail "address none must be recorded"
  printf 'export KEEP=1\n' > "$fake/.zshrc"
  printf '# bash\n' > "$fake/.bashrc"
  HOME="$fake" run "$h" "$c" shortcut add --name jv --folder "$fake/work" > "$TMP_ROOT/sc.out" || fail "shortcut add must succeed"
  grep -q 'Undo: .*shortcut remove --name jv' "$TMP_ROOT/sc.out" || fail "shortcut add must print the undo command"
  for rc in "$fake/.zshrc" "$fake/.bashrc"; do
    grep -qx "alias jv='cd $fake/work && $ROOT/bin/jarvis-launch'" "$rc" || fail "$rc must carry the alias: $(cat "$rc")"
  done
  before=$(cat "$fake/.zshrc")
  HOME="$fake" run "$h" "$c" shortcut add --name jv --folder "$fake/work" >/dev/null
  [ "$(cat "$fake/.zshrc")" = "$before" ] || fail "a second add must be idempotent"
  [ "$(cat "$h/config/shortcut")" = "jv $fake/work" ] || fail "the shortcut choice must be recorded"
  HOME="$fake" run "$h" "$c" shortcut remove --name jv >/dev/null
  [ "$(cat "$fake/.zshrc")" = "export KEEP=1" ] || fail "remove must leave the rest of the file as it was: $(cat "$fake/.zshrc")"
  grep -q jarvis-launch "$fake/.bashrc" && fail "remove must clear every rc file"
  run "$h" "$c" shortcut add --name 'bad name' >/dev/null 2>&1 && fail "a name with a space must be refused"
  out=$(run "$h" "$c" shortcut none; run "$h" "$c" detect)
  printf '%s' "$out" | grep -q 'launch shortcut not offered\|address the user' && fail "recorded choices must silence both questions: '$out'"
  pass "jarvis-setup: address and shortcut are asked once; the alias block is marked, idempotent and removable"
}

test_status_explains_backend() {
  local h="$TMP_ROOT/bk" c="$TMP_ROOT/bk-claude" out
  mkdir -p "$h/config" "$c"
  st() { env -u TMUX -u HERDR_ENV -u ZELLIJ -u FM_BACKEND CMUX_WORKSPACE_ID=ws-test "$@"; }
  echo herdr > "$h/config/backend"
  out=$(st JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" status)
  printf '%s\n' "$out" | grep -qx 'ok: backend saved choice: herdr (config/backend)' || fail "status must show the saved choice: $out"
  printf '%s\n' "$out" | grep -qx 'ok: terminal detected: cmux' || fail "status must show the detected terminal: $out"
  printf '%s\n' "$out" | grep -q '^ok: new workers spawn in: herdr (the saved choice wins over the cmux terminal' \
    || fail "a saved herdr choice in cmux must spawn in herdr and say why: $out"
  printf '%s\n' "$out" | grep -q "a task's own --backend can differ" || fail "status must say a per-task override can differ"
  [ "$(cat "$h/config/backend")" = herdr ] || fail "status must not change the saved choice"
  rm "$h/config/backend"
  echo auto > "$h/config/jarvis-backend"
  out=$(st JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" status)
  printf '%s\n' "$out" | grep -qx 'ok: backend saved choice: none (auto)' || fail "auto must show no saved choice: $out"
  printf '%s\n' "$out" | grep -q '^ok: new workers spawn in: cmux (no saved choice, so the detected terminal' \
    || fail "auto in cmux must spawn in cmux: $out"
  out=$(st FM_BACKEND=tmux JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$SETUP" status)
  printf '%s\n' "$out" | grep -q '^ok: new workers spawn in: tmux (FM_BACKEND is set' || fail "FM_BACKEND must still win: $out"
  pass "jarvis-setup: status shows the saved backend, the detected terminal and where new workers spawn, separately"
}

# The manager's name: default JarvisAIGeorge (detect says nothing), a set name is
# printed for the session and used for the cmux manager tab, and detect names the
# tab at session start under a Codex manager too (stub cmux, no worker spawned).
test_manager_name_and_tab() {
  local h="$TMP_ROOT/name" c="$TMP_ROOT/name-claude" bin="$TMP_ROOT/name-bin" out
  mkdir -p "$h" "$c" "$bin"
  out=$(run "$h" "$c" detect | grep '^JARVIS_MANAGER_NAME' || true)
  [ -z "$out" ] || fail "the default name must not print a line: $out"
  run "$h" "$c" name Ada >/dev/null || fail "name must succeed"
  out=$(run "$h" "$c" detect | grep '^JARVIS_MANAGER_NAME' || true)
  assert_equals "JARVIS_MANAGER_NAME: Ada" "$out" "a set name is printed at session start"
  run "$h" "$c" name a/b >/dev/null 2>&1 && fail "a name with a slash must be refused"
  echo workers > "$h/config/cmux-layout"
  cat > "$bin/cmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bin/cmux.calls"
case "\$*" in
  'rpc system.tree'*) printf '%s' '{"windows":[{"id":"w1","workspace_count":1,"selected_workspace_id":"ws-mgr","workspaces":[{"id":"ws-mgr","ref":"workspace:1","title":"x","panes":[{"id":"p1","surface_count":1,"surface_ids":["s1"],"surfaces":[{"id":"s1"}]}]}]}]}' ;;
esac
exit 0
STUB
  chmod +x "$bin/cmux"
  PATH="$bin:$PATH" CMUX_WORKSPACE_ID=ws-mgr JARVIS_HARNESS=codex FM_HOME="$h" CODEX_HOME="$c" "$SETUP" detect >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q 'rename --title Ada' "$bin/cmux.calls" 2>/dev/null && break
    sleep 0.25
  done
  assert_grep "workspace-action --workspace ws-mgr --window w1 --action rename --title Ada" "$bin/cmux.calls" "detect names the Codex manager's tab"
  run "$h" "$c" name default >/dev/null
  [ ! -e "$h/config/manager-name" ] || fail "name default must remove the override"
  pass "jarvis-setup: manager name defaults to JarvisAIGeorge, prints when set, and names the cmux tab at session start (Codex)"
}

test_backend_choice
test_manager_name_and_tab
test_detect_names_gaps
test_update_check_off
test_codex_install_commands
test_claude_install_commands
test_installed_from_either_marketplace
test_codex_sessionstart_hook
test_address_and_shortcut
test_status_explains_backend
