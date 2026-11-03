#!/usr/bin/env bash
# tests/jarvis-plugin-versioning.test.sh - a plugin update never breaks a running
# session.
#
# Claude Code caches a plugin by version and a live session keeps the folder of
# the version it started with (verified with a throwaway CLAUDE_CONFIG_DIR on
# 2.1.316: a bump adds a new folder and marks the old one `.orphaned_at`; the old
# folder stays; a same-version change is "already at the latest version" and
# never ships). So:
#   - the build bumps the version when plugin files change, and --check fails
#     on a change without a bump;
#   - every plugin hook command runs only files in its own plugin folder and
#     exits 0 quietly when that folder is gone;
#   - the update notice prints once per session when its folder is orphaned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-plugin-versioning-tests)
export JARVIS_HOME_POINTER="$TMP_ROOT/home-pointer"
HOOKS="$ROOT/plugins/jarvis-ai-george/hooks/hooks.json"

test_hook_commands_self_contained() {
  python3 - "$HOOKS" "$ROOT/plugins/jarvis-ai-george" <<'PY' || fail "a plugin hook reaches outside its plugin folder"
import json, os, re, sys
hooks, plugin = json.load(open(sys.argv[1]))["hooks"], sys.argv[2]
for event, groups in hooks.items():
    for g in groups:
        for h in g["hooks"]:
            c = h["command"]
            paths = re.findall(r'\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)', c)
            assert paths, f"{event}: command does not run a plugin file: {c}"
            for p in paths:
                assert os.path.isfile(os.path.join(plugin, p)), f"{event}: {p} is not in the plugin"
            for bad in ("CLAUDE_PROJECT_DIR", "JARVIS_HOME", "FM_HOME", "$HOME/", "~/"):
                assert bad not in c, f"{event}: command reaches {bad}: {c}"
PY
  pass "plugin hooks: every command runs only files inside \${CLAUDE_PLUGIN_ROOT}"
}

test_hook_commands_quiet_when_folder_gone() {
  local gone="$TMP_ROOT/gone/0.0.1" cmd out status n=0
  while IFS= read -r cmd; do
    n=$((n + 1))
    out=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse"}' \
      | CLAUDE_PLUGIN_ROOT="$gone" bash -c "$cmd" 2>&1); status=$?
    expect_code 0 "$status" "hook command with a removed plugin folder"
    [ -z "$out" ] || fail "hook command printed with a removed plugin folder: $out"
  done < <(jq -r '.hooks[][].hooks[].command' "$HOOKS")
  [ "$n" -gt 0 ] || fail "no hook commands found"
  pass "plugin hooks: all $n commands exit 0 and print nothing when the version folder was removed"
}

test_update_notice_once_per_session() {
  local plugin="$TMP_ROOT/notice/0.1.0" state="$TMP_ROOT/notice-state" out
  mkdir -p "$plugin/hooks"
  cp "$ROOT/plugins/jarvis-ai-george/hooks/jarvis-update-notice.sh" "$plugin/hooks/"
  run() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" \
    | CLAUDE_PLUGIN_ROOT="$plugin" JARVIS_NOTICE_STATE="$state" bash "$plugin/hooks/jarvis-update-notice.sh"; }
  out=$(run sA); [ -z "$out" ] || fail "notice printed for a current plugin folder: $out"
  printf '1700000000000' > "$plugin/.orphaned_at"
  out=$(run sA); assert_contains "$out" '"systemMessage":"Jarvis was updated. Restart to load it."' "first prompt of an old session"
  out=$(run sA); [ -z "$out" ] || fail "notice repeated in the same session: $out"
  out=$(run sB); assert_contains "$out" "Restart to load it" "a second old session gets its own notice"
  out=$(printf 'not json' | CLAUDE_PLUGIN_ROOT="$plugin" JARVIS_NOTICE_STATE="$state" bash "$plugin/hooks/jarvis-update-notice.sh"); status=$?
  expect_code 0 "$status" "notice with a bad payload"
  pass "update notice: silent while current, once per old session, quiet on a bad payload"
}

# A copy of the working tree, committed, with an origin/main so the gate has a
# real base.
gate_repo() {
  local dir=$1
  fm_git_identity
  mkdir -p "$dir"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$dir"
  git -C "$dir" init -q -b main && git -C "$dir" add -A && git -C "$dir" commit -qm base
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
}

test_version_gate() {
  local repo="$TMP_ROOT/gate" out status v0 v1
  gate_repo "$repo"
  v0=$(jq -r .version "$repo/plugins/jarvis-ai-george/jarvis-extension.json")
  out=$(cd "$repo" && python3 tools/jarvis-build.py --check 2>&1); status=$?
  expect_code 0 "$status" "clean tree passes the gate: $out"
  printf '\n# changed\n' >> "$repo/plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh"
  out=$(cd "$repo" && python3 tools/jarvis-build.py --check 2>&1); status=$?
  expect_code 1 "$status" "a plugin change without a bump"
  assert_contains "$out" "version is still $v0" "the gate names the stale version"
  assert_contains "$out" "plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh" "the gate names the changed file"
  out=$(cd "$repo" && python3 tools/jarvis-build.py 2>&1); status=$?
  expect_code 0 "$status" "the build bumps: $out"
  v1=$(jq -r .version "$repo/plugins/jarvis-ai-george/jarvis-extension.json")
  assert_not_equals "$v0" "$v1" "the build moved the version"
  assert_equals "$v1" "$(jq -r .version "$repo/plugins/jarvis-ai-george/.claude-plugin/plugin.json")" "plugin.json carries the bump"
  assert_equals "$v1" "$(jq -r '.plugins[] | select(.name=="jarvis-ai-george") | .version' "$repo/.claude-plugin/marketplace.json")" "the marketplace carries the bump"
  out=$(cd "$repo" && python3 tools/jarvis-build.py 2>&1)
  assert_equals "$v1" "$(jq -r .version "$repo/plugins/jarvis-ai-george/jarvis-extension.json")" "a second build does not bump again"
  out=$(cd "$repo" && python3 tools/jarvis-build.py --check 2>&1); status=$?
  expect_code 0 "$status" "bumped tree passes: $out"
  git -C "$repo" add -A && git -C "$repo" commit -qm bumped
  base=$(git -C "$repo" rev-parse HEAD)
  printf '\n# docs only\n' >> "$repo/README.md"
  out=$(cd "$repo" && python3 tools/jarvis-build.py --check --base "$base" 2>&1); status=$?
  expect_code 0 "$status" "a change outside the plugin needs no bump: $out"
  out=$(cd "$repo" && python3 tools/jarvis-build.py --check --base 0000000000000000000000000000000000000000 2>&1); status=$?
  expect_code 0 "$status" "a zero base (new branch push) skips the gate: $out"
  pass "version gate: --check fails on an unbumped plugin change, a build bumps once, outside changes and new branches pass"
}

test_hook_commands_self_contained
test_hook_commands_quiet_when_folder_gone
test_update_notice_once_per_session
test_version_gate
