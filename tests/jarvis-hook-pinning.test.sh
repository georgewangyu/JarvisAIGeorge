#!/usr/bin/env bash
# tests/jarvis-hook-pinning.test.sh - an update never breaks a running session.
#
# Home hooks: every entry in .claude/settings.json and .codex/hooks.json calls
# the stable bin/hook dispatcher. A session start pins the session to a snapshot
# of the home's hook code, so after a `git pull` that changes a hook script
# incompatibly, the old session keeps running its old code cleanly while a new
# session runs the new code, both at once.
# Plugin hooks: an old session keeps its orphaned version folder while a new
# session runs the bumped one.
#
# The harnesses are stubs: each test runs the tracked hook command strings the
# way Claude Code (CLAUDE_PROJECT_DIR, sh -c) and Codex (cwd = home, bash -lc)
# do. The live Codex run is verified on a personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-hook-pinning-tests)
NOTICE="$TMP_ROOT/notice"
export JARVIS_NOTICE_STATE="$NOTICE"
fm_git_identity

# A home whose hook scripts are stubs: each prints its version and the env it
# ran with. v1 sources lib-v1.sh; v2 deletes it and needs lib-v2.sh, so v1 code
# run against a v2 checkout would fail.
STUBS="fm-sessionstart-run.sh jarvis-setup.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh fm-turnend-guard.sh fm-claude-stop-autoarm.sh jarvis-manager-write-guard.sh"
write_stubs() {  # <home> <version>
  local home=$1 v=$2 s
  rm -f "$home"/bin/lib-v*.sh
  printf 'LIBV=%s\n' "$v" > "$home/bin/lib-$v.sh"
  for s in $STUBS; do
    cat > "$home/bin/$s" <<EOF
#!/usr/bin/env bash
here=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd -P)
. "\$here/lib-$v.sh" || { echo "BROKEN $s"; exit 1; }
payload=\$(cat)
printf '%s %s lib=%s home=%s root=%s args=%s\n' "$v" "$s" "\$LIBV" "\${FM_HOME:-}" "\${FM_ROOT_OVERRIDE:-}" "\$*"
printf '%s\n' "\$payload" | grep -q session_id || echo "NO PAYLOAD"
echo "$v" >> "\${FM_HOME:-\$here/..}/state/ran"
EOF
    chmod +x "$home/bin/$s"
  done
}

make_home() {  # <dir>
  local home=$1
  mkdir -p "$home/bin" "$home/.claude" "$home/.codex" "$home/state"
  cp "$ROOT/bin/hook" "$home/bin/hook"
  cp "$ROOT/.claude/settings.json" "$home/.claude/settings.json"
  cp "$ROOT/.codex/hooks.json" "$home/.codex/hooks.json"
  printf '# home\n' > "$home/AGENTS.md"
  printf 'state/\n' > "$home/.gitignore"
  write_stubs "$home" v1
  git -C "$home" init -q -b main
  git -C "$home" add -A && git -C "$home" commit -qm v1
}

pull_v2() {  # <home>: what `git pull` of an incompatible hook change does
  write_stubs "$1" v2
  git -C "$1" add -A && git -C "$1" commit -qm v2
}

payload() {  # <event> <session> [source]
  printf '{"session_id":"%s","transcript_path":"/tmp/t","cwd":"/tmp","hook_event_name":"%s","source":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    "$2" "$1" "${3:-startup}"
}

# Stub Claude Code: run the tracked settings.json commands for one event.
claude_event() {  # <home> <event> <session> [source]
  local home=$1 ev=$2 sid=$3 src=${4:-startup} cmd
  while IFS= read -r cmd; do
    payload "$ev" "$sid" "$src" | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$home" sh -c "$cmd" 2>&1
  done < <(jq -r --arg e "$ev" '.hooks[$e][]?.hooks[].command' "$home/.claude/settings.json")
}

# Stub Codex: cwd is the home, commands run under bash -lc as written.
codex_event() {  # <home> <event> <session> [source]
  local home=$1 ev=$2 sid=$3 src=${4:-startup} cmd
  while IFS= read -r cmd; do
    payload "$ev" "$sid" "$src" | (cd "$home" && sh -c "$cmd") 2>&1
  done < <(jq -r --arg e "$ev" '.hooks[$e][]?.hooks[].command' "$home/.codex/hooks.json")
}

test_side_by_side() {  # <harness>
  local h=$1 home="$TMP_ROOT/home-$1" ev out real
  make_home "$home"
  ev="${h}_event"
  real=$(cd "$home" && pwd -P)

  out=$($ev "$home" SessionStart old)
  assert_contains "$out" "v1 fm-sessionstart-run.sh lib=v1" "$h: old session starts on v1"
  assert_contains "$out" "home=$real root=$real" "$h: pinned code runs with the live home as FM_HOME and root"
  assert_not_contains "$out" "NO PAYLOAD" "$h: the payload reaches the script"
  [ -d "$home/state/hook-releases/$(git -C "$home" rev-parse HEAD)/bin" ] || fail "$h: no snapshot for v1"

  pull_v2 "$home"

  out=$($ev "$home" PreToolUse old)
  assert_contains "$out" "v1 fm-arm-pretool-check.sh lib=v1" "$h: old session keeps v1 after the pull"
  assert_not_contains "$out" "BROKEN" "$h: old session's hooks run cleanly"
  assert_not_contains "$out" "v2" "$h: old session never runs v2 code"

  out=$($ev "$home" SessionStart new)
  assert_contains "$out" "v2 fm-sessionstart-run.sh lib=v2" "$h: new session starts on v2"

  out=$($ev "$home" Stop old)
  assert_contains "$out" "v1 fm-turnend-guard.sh lib=v1" "$h: old session Stop still v1 while the new one is up"
  out=$($ev "$home" Stop new)
  assert_contains "$out" "v2 fm-turnend-guard.sh lib=v2" "$h: new session Stop is v2"
  assert_grep "v1" "$home/state/ran" "$h: v1 wrote to the live state"
  assert_grep "v2" "$home/state/ran" "$h: v2 wrote to the live state"

  out=$($ev "$home" UserPromptSubmit old)
  assert_contains "$out" '{"systemMessage":"Jarvis was updated. Restart to load it."}' "$h: old session gets the notice"
  out=$($ev "$home" UserPromptSubmit old)
  assert_not_contains "$out" "Restart" "$h: the notice shows once"
  out=$($ev "$home" UserPromptSubmit new)
  assert_not_contains "$out" "Restart" "$h: a current session gets no notice"

  out=$($ev "$home" SessionStart old compact)
  assert_contains "$out" "v1 fm-sessionstart-run.sh" "$h: a compact keeps the pin"
  out=$($ev "$home" SessionStart old resume)
  assert_contains "$out" "v2 fm-sessionstart-run.sh" "$h: a resume (a restart) loads the update"
  pass "$h: old session runs v1 cleanly after an incompatible pull, new session runs v2, both at once; one notice"
}

test_fallbacks() {
  local home="$TMP_ROOT/home-fallback" out
  make_home "$home"
  out=$(printf '{}' | CLAUDE_PROJECT_DIR="$home" "$home/bin/hook" fm-turnend-guard.sh)
  assert_contains "$out" "v1 fm-turnend-guard.sh" "no session id runs the live script"
  out=$(payload PreToolUse unknown | "$home/bin/hook" fm-turnend-guard.sh)
  assert_contains "$out" "v1 fm-turnend-guard.sh" "an unpinned session runs the live script"
  payload SessionStart s1 | "$home/bin/hook" fm-sessionstart-run.sh >/dev/null
  rm -rf "$home"/state/hook-releases/*/
  out=$(payload PreToolUse s1 | "$home/bin/hook" fm-turnend-guard.sh)
  assert_contains "$out" "v1 fm-turnend-guard.sh" "a removed snapshot falls back to the live script"
  out=$(payload PreToolUse s1 | "$home/bin/hook" no-such-script.sh; echo "rc=$?")
  assert_equals "rc=0" "$out" "an unknown script exits 0 quietly"
  out=$(payload PreToolUse s1 | "$home/bin/hook" ../escape.sh; echo "rc=$?")
  assert_equals "rc=0" "$out" "a path in the name is refused quietly"
  out=$(: | "$home/bin/hook" --require-payload fm-turnend-guard.sh; echo "rc=$?")
  assert_equals "rc=0" "$out" "--require-payload skips an empty stdin"
  printf '\n# local edit\n' >> "$home/bin/fm-turnend-guard.sh"
  payload SessionStart s2 | "$home/bin/hook" fm-sessionstart-run.sh >/dev/null
  ls -d "$home"/state/hook-releases/*-dirty-* >/dev/null 2>&1 || fail "a local edit gets its own dirty snapshot"
  pass "bin/hook: unpinned, missing-snapshot and bad-name cases fail quiet; local edits pin a dirty snapshot"
}

test_prune() {
  local home="$TMP_ROOT/home-prune" rel old live
  make_home "$home"
  rel="$home/state/hook-releases"
  payload SessionStart cur | "$home/bin/hook" fm-sessionstart-run.sh >/dev/null
  for old in deadbeef1 deadbeef2 deadbeef3; do
    mkdir -p "$rel/$old/bin" && printf '%s\n' "$old" > "$rel/$old/.release"
    touch -t 2001010000 "$rel/$old/.release"
  done
  sleep 30 & live=$!
  printf 'deadbeef2 %s\n' "$live" > "$rel/sessions/livesession"
  printf 'deadbeef3 999999\n' > "$rel/sessions/deadsession"
  touch -t 2001010000 "$rel/sessions/deadsession"
  rm -f "$rel/.pruned"
  payload SessionStart cur2 | "$home/bin/hook" fm-sessionstart-run.sh >/dev/null
  kill "$live" 2>/dev/null
  [ ! -d "$rel/deadbeef1" ] || fail "an old unused snapshot was kept"
  [ -d "$rel/deadbeef2" ] || fail "a snapshot a live session uses was pruned"
  [ ! -d "$rel/deadbeef3" ] || fail "a dead session's old snapshot was kept"
  [ ! -f "$rel/sessions/deadsession" ] || fail "a dead session record was kept"
  [ -d "$rel/$(git -C "$home" rev-parse HEAD)" ] || fail "the current snapshot was pruned"
  pass "bin/hook prune: old unused snapshots go, a live session's and the current one stay"
}

# Plugin side: a bump leaves the old session on its own version folder.
test_plugin_bump_side_by_side() {
  local cache="$TMP_ROOT/cache/jarvis-ai-george/jarvis-ai-george" cmd out
  mkdir -p "$cache"
  cp -R "$ROOT/plugins/jarvis-ai-george" "$cache/0.0.1"
  cp -R "$ROOT/plugins/jarvis-ai-george" "$cache/0.0.2"
  printf '#!/usr/bin/env bash\ncat >/dev/null; echo old-sidebar\n' > "$cache/0.0.1/hooks/jarvis-sidebar.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null; echo new-sidebar\n' > "$cache/0.0.2/hooks/jarvis-sidebar.sh"
  printf '1700000000000' > "$cache/0.0.1/.orphaned_at"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$cache/0.0.1/hooks/hooks.json")
  out=$(payload PreToolUse old | CLAUDE_PLUGIN_ROOT="$cache/0.0.1" sh -c "$cmd")
  assert_equals "old-sidebar" "$out" "old session runs its own plugin folder"
  out=$(payload PreToolUse new | CLAUDE_PLUGIN_ROOT="$cache/0.0.2" sh -c "$cmd")
  assert_equals "new-sidebar" "$out" "new session runs the bumped folder"
  out=""
  while IFS= read -r cmd; do
    out+=$(payload UserPromptSubmit pold | CLAUDE_PLUGIN_ROOT="$cache/0.0.1" sh -c "$cmd")
  done < <(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$cache/0.0.1/hooks/hooks.json")
  assert_contains "$out" "Restart to load it" "old plugin session gets the notice"
  out=$(payload UserPromptSubmit pnew | CLAUDE_PLUGIN_ROOT="$cache/0.0.2" bash "$cache/0.0.2/hooks/jarvis-update-notice.sh")
  [ -z "$out" ] || fail "a current plugin session got a notice: $out"
  rm -rf "$cache/0.0.1"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$cache/0.0.2/hooks/hooks.json")
  out=$(payload PreToolUse old | CLAUDE_PLUGIN_ROOT="$cache/0.0.1" sh -c "$cmd"; echo "rc=$?")
  assert_equals "rc=0" "$out" "a removed old folder exits 0 quietly"
  pass "plugin bump: old session keeps its folder and gets one notice, new session runs the new folder, a removed folder is quiet"
}

test_side_by_side claude
test_side_by_side codex
test_fallbacks
test_prune
test_plugin_bump_side_by_side
