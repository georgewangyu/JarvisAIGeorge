#!/usr/bin/env bash
# tests/jarvis-home-discovery.test.sh - a manager started in any folder finds
# its home (issue #17).
#
# Setup records the clone in a user-level pointer file. The one resolver
# (plugins/jarvis-ai-george/hooks/jarvis-home.sh, wrapped by bin/jarvis-home)
# reads JARVIS_HOME, then the pointer, then the current folder. The core
# plugin's SessionStart hook (stub Claude: the tracked hooks.json command with a
# manager payload) exports JARVIS_HOME and FM_HOME into the session or says "No
# Jarvis home found". Codex has no such hook: its role runs the same resolver
# (stub Codex: the command the role names, run from a random folder). The live
# Codex run is verified on a personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-home-discovery-tests)
export JARVIS_HOME_POINTER="$TMP_ROOT/pointer/home"
HOOKS="$ROOT/plugins/jarvis-ai-george/hooks/hooks.json"
RESOLVER="$ROOT/plugins/jarvis-ai-george/hooks/jarvis-home.sh"

make_home() {  # <dir>: the minimum that makes a folder a home
  mkdir -p "$1/bin"
  : > "$1/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$1/bin/jarvis-setup.sh"
  chmod +x "$1/bin/jarvis-setup.sh"
}

# Stub Claude: run the plugin's SessionStart commands for a manager session in <cwd>.
claude_start() {  # <cwd> <agent_type> [env...]
  local cwd=$1 agent=$2 cmd out=""
  shift 2
  : > "$TMP_ROOT/envfile"
  while IFS= read -r cmd; do
    case "$cmd" in *jarvis-home.sh*) ;; *) continue ;; esac
    out+=$(printf '{"session_id":"s","hook_event_name":"SessionStart","source":"startup","agent_type":"%s"}' "$agent" \
      | (cd "$cwd" && env -u JARVIS_HOME -u FM_HOME "$@" CLAUDE_PLUGIN_ROOT="$ROOT/plugins/jarvis-ai-george" \
          CLAUDE_PROJECT_DIR="$cwd" CLAUDE_ENV_FILE="$TMP_ROOT/envfile" sh -c "$cmd"))
  done < <(jq -r '.hooks.SessionStart[].hooks[].command' "$HOOKS")
  printf '%s' "$out"
}

test_pointer_from_random_folder() {
  local home="$TMP_ROOT/clone-a" far="$TMP_ROOT/somewhere/else" out real
  make_home "$home"
  mkdir -p "$far" "$(dirname "$JARVIS_HOME_POINTER")"
  real=$(cd "$home" && pwd -P)
  printf '%s\n' "$real" > "$JARVIS_HOME_POINTER"
  out=$(claude_start "$far" jarvis-ai-george:jarvis-ai-george)
  assert_contains "$out" "JARVIS_HOME: $real (found from pointer" "a random folder finds the home from the pointer"
  assert_contains "$out" "bin/fm-session-start.sh once" "a hand-made start is told to run the home's session start"
  assert_grep "export JARVIS_HOME=$real" "$TMP_ROOT/envfile" "JARVIS_HOME is exported into the session"
  assert_grep "export FM_HOME=$real" "$TMP_ROOT/envfile" "FM_HOME is set to match"
  out=$(cd "$far" && env -u JARVIS_HOME bash "$RESOLVER" resolve)
  assert_equals "$real" "$out" "stub Codex: the resolver the role names finds the home from any folder"
  out=$(cd "$far" && env -u JARVIS_HOME -u FM_HOME bash "$RESOLVER" env)
  assert_contains "$out" "export FM_HOME=$real" "the env form sets FM_HOME to match"
  pass "random folder, no env: the pointer finds the home and FM_HOME follows (Claude hook, Codex resolver)"
}

test_no_home() {
  local far="$TMP_ROOT/lonely" out status
  mkdir -p "$far"
  rm -f "$JARVIS_HOME_POINTER"
  out=$(claude_start "$far" jarvis-ai-george)
  assert_contains "$out" "JARVIS_NO_HOME: No Jarvis home found" "no pointer and no env gives the clear message"
  assert_contains "$out" "bin/jarvis-setup.sh home" "the message carries the fix"
  assert_contains "$out" "do not act as if a fleet is ready" "the manager is told not to act ready"
  [ ! -s "$TMP_ROOT/envfile" ] || fail "nothing is exported without a home"
  out=$(cd "$far" && env -u JARVIS_HOME bash "$RESOLVER" resolve 2>&1); status=$?
  expect_code 1 "$status" "stub Codex: resolve fails without a home"
  assert_contains "$out" "No Jarvis home found" "stub Codex gets the same message"
  pass "no pointer and no env: 'No Jarvis home found' with the fix, nothing exported"
}

test_stale_pointer() {
  local gone="$TMP_ROOT/deleted-clone" far="$TMP_ROOT/far2" other="$TMP_ROOT/clone-other" out
  make_home "$gone"
  make_home "$other"
  mkdir -p "$far"
  printf '%s\n' "$gone" > "$JARVIS_HOME_POINTER"
  rm -rf "$gone"
  out=$(claude_start "$far" jarvis-ai-george)
  assert_contains "$out" "No Jarvis home found: the pointer" "a stale pointer gives the clear message"
  assert_contains "$out" "deleted or moved" "the stale pointer is named as such"
  out=$(claude_start "$other" jarvis-ai-george)
  [ -z "$out" ] || fail "inside a home the hook is quiet (that home's own hooks run): $out"
  pass "a stale pointer is an error, never a fall-through"
}

test_two_clones_explicit() {
  local a="$TMP_ROOT/two-a" b="$TMP_ROOT/two-b" far="$TMP_ROOT/far3" out rb
  make_home "$a"
  make_home "$b"
  mkdir -p "$far"
  rb=$(cd "$b" && pwd -P)
  printf '%s\n' "$(cd "$a" && pwd -P)" > "$JARVIS_HOME_POINTER"
  out=$(claude_start "$far" jarvis-ai-george JARVIS_HOME="$b")
  assert_contains "$out" "JARVIS_HOME: $rb (found from env" "an explicit JARVIS_HOME picks the second clone over the pointer"
  out=$(claude_start "$far" jarvis-ai-george JARVIS_HOME="$far")
  assert_contains "$out" "JARVIS_HOME=$far is not a JarvisAIGeorge home" "a wrong explicit choice is an error, not a fall-back"
  pass "two clones: the explicit choice wins, a wrong one is reported"
}

test_only_the_manager() {
  local far="$TMP_ROOT/far4" out
  mkdir -p "$far"
  rm -f "$JARVIS_HOME_POINTER"
  out=$(claude_start "$far" george-coding-agent:coding)
  [ -z "$out" ] || fail "a worker agent gets no home lookup: $out"
  out=$(claude_start "$far" "")
  [ -z "$out" ] || fail "a plain session gets no home lookup: $out"
  pass "the lookup speaks only for the manager agent"
}

test_setup_records_pointer() {
  local h="$TMP_ROOT/setup-home" c="$TMP_ROOT/setup-claude" other="$TMP_ROOT/setup-other" rr out
  mkdir -p "$h" "$c"
  make_home "$other"
  rr=$(cd "$ROOT" && pwd -P)
  rm -f "$JARVIS_HOME_POINTER"
  JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$ROOT/bin/jarvis-setup.sh" detect >/dev/null
  assert_equals "$rr" "$(cat "$JARVIS_HOME_POINTER")" "detect records the clone when no pointer exists"
  printf '%s\n' "$TMP_ROOT/gone-away" > "$JARVIS_HOME_POINTER"
  JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$ROOT/bin/jarvis-setup.sh" detect >/dev/null
  assert_equals "$rr" "$(cat "$JARVIS_HOME_POINTER")" "detect refreshes a stale pointer"
  printf '%s\n' "$other" > "$JARVIS_HOME_POINTER"
  JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$ROOT/bin/jarvis-setup.sh" detect >/dev/null
  assert_equals "$other" "$(cat "$JARVIS_HOME_POINTER")" "detect keeps a pointer to another live home"
  out=$(JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$c" "$ROOT/bin/jarvis-setup.sh" home)
  assert_contains "$out" "ok: home $rr recorded" "setup home makes this clone the home explicitly"
  assert_equals "$rr" "$(cat "$JARVIS_HOME_POINTER")" "setup home replaced the pointer"
  out=$(cd "$TMP_ROOT" && env -u JARVIS_HOME "$ROOT/bin/jarvis-home" resolve)
  assert_equals "$rr" "$out" "bin/jarvis-home is the same resolver"
  pass "setup records the pointer once, refreshes a stale one, keeps another live home, and setup home switches it"
}

test_shortcut_still_launch() {
  grep -q "bin/jarvis-launch'" "$ROOT/bin/jarvis-setup.sh" || fail "the generated shortcut must still run jarvis-launch"
  grep -q 'No Jarvis home found' "$ROOT/plugins/jarvis-ai-george/skills/role-jarvis/SKILL.md" || fail "role-jarvis (Codex) carries the no-home rule"
  grep -q 'bin/jarvis-home resolve' "$ROOT/plugins/jarvis-ai-george/skills/role-jarvis/SKILL.md" || fail "role-jarvis (Codex) names the resolver"
  pass "the shortcut still uses jarvis-launch, and the Codex role carries the lookup and the no-home rule"
}

test_pointer_from_random_folder
test_no_home
test_stale_pointer
test_two_clones_explicit
test_only_the_manager
test_setup_records_pointer
test_shortcut_still_launch
