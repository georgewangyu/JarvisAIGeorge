#!/usr/bin/env bash
# tests/jarvis-sidebar.test.sh - the core plugin's cmux sidebar hook
# (plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh) against a logging fake
# cmux, a fake gh, and real git. No real cmux and no agent run. Live evidence:
# docs/cmux-backend.md "Sidebar".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh"
TMP_ROOT=$(fm_test_tmproot jarvis-sidebar-tests)
# The oldest shell the hook must run on (macOS ships bash 3.2 as /bin/bash).
HB=/bin/bash; [ -x "$HB" ] || HB=bash
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# new_case <name>: a fake cmux that logs one line per call; set-status fails
# while <case>/fail-set exists.
new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/bin"
  cat > "$d/bin/cmux" <<'SH'
#!/usr/bin/env bash
[ "$1" = set-status ] && [ -f "$SB_CASE/fail-set" ] && exit 1
printf '%s\n' "$*" >> "$SB_CASE/log"
SH
  chmod +x "$d/bin/cmux"
  : > "$d/log"
  printf '%s\n' "$d"
}

# ev <case> <json> [env...]: one hook run with the writer inline.
ev() {
  local d=$1 j=$2
  shift 2
  printf '%s' "$j" | env PATH="$d/bin:$PATH" SB_CASE="$d" CMUX_WORKSPACE_ID=ws1 \
    JARVIS_SIDEBAR_STATE="$d/state" JARVIS_SIDEBAR_SYNC=1 JARVIS_SIDEBAR_CLIENT_PID=$$ \
    JARVIS_SIDEBAR_GH=no-gh-here "$@" "$HB" "$HOOK"
}

# last <case> <key>: the last command sent for a pill key.
last() { grep -E "^(set|clear)-status $2( |$)" "$1/log" | tail -1; }

test_noop_outside_cmux_and_silent() {
  local d out
  d=$(new_case noop)
  out=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}' \
    | env -u CMUX_WORKSPACE_ID PATH="$d/bin:$PATH" SB_CASE="$d" JARVIS_SIDEBAR_STATE="$d/state" JARVIS_SIDEBAR_SYNC=1 "$HB" "$HOOK"; echo "rc=$?")
  [ "$out" = "rc=0" ] || fail "outside cmux the hook must print nothing and exit 0: $out"
  [ ! -s "$d/log" ] && [ ! -e "$d/state" ] || fail "outside cmux the hook must not touch cmux or state"
  out=$(ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hello"}'; ev "$d" 'not json'; echo "rc=$?")
  [ "$out" = "rc=0" ] || fail "inside cmux the hook must still print nothing and exit 0: $out"
  pass "sidebar: a no-op outside cmux; never writes stdout; exits 0 on any input"
}

test_activity_and_tool_lines() {
  local d
  d=$(new_case life)
  ev "$d" '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}'
  last "$d" jarvis_activity | grep -q 'set-status jarvis_activity Ready --icon checkmark' || fail "start must show Ready"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Fix the login bug"}'
  last "$d" jarvis_activity | grep -q 'Working: Fix the login bug' || fail "a prompt must show Working with the ask"
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git status"}}'
  last "$d" jarvis_tool | grep -q 'Checking git status' || fail "the tool line must show the current tool"
  ev "$d" '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"git status"}}'
  last "$d" jarvis_tool | grep -q 'Checked git status --icon checkmark' || fail "a finished tool must show its past form"
  ev "$d" '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Done."}'
  last "$d" jarvis_activity | grep -q 'Done: Checked git status' || fail "stop must show Done with the last step"
  last "$d" jarvis_tool | grep -q '^clear-status jarvis_tool' || fail "stop must clear the tool line"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Survey it"}'
  ev "$d" '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/notes.md"}}'
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"<task-notification><task-id>b1</task-id></task-notification>"}'
  last "$d" jarvis_activity | grep -q 'Working: Survey it' || fail "a harness notification prompt must keep the ask"
  ev "$d" '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Noted."}'
  last "$d" jarvis_activity | grep -q 'Done: Read notes.md' || fail "a harness notification prompt must keep the last step"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Which one?"}'
  ev "$d" '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Should I keep the old API?"}'
  last "$d" jarvis_activity | grep -q 'Waiting: Which one?' || fail "a turn ending on a question must show Waiting"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Run it"}'
  ev "$d" '{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","tool_input":{"command":"make"}}'
  last "$d" jarvis_tool | grep -q 'Bash failed' || fail "a failed tool must say so"
  ev "$d" '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"It broke."}'
  last "$d" jarvis_activity | grep -q 'set-status jarvis_activity Error' || fail "a turn with a failed tool must end as Error"
  ev "$d" '{"hook_event_name":"SessionEnd","session_id":"s1"}'
  last "$d" jarvis_activity | grep -q '^clear-status jarvis_activity' || fail "session end must clear the activity line"
  [ ! -e "$d/state/ws1" ] || fail "session end must forget the surface once every pill is cleared"
  pass "sidebar: Ready, Working: <ask>, tool line, Done, Waiting, Error, notification prompts, and a clean session end"
}

test_permission_and_notifications() {
  local d
  d=$(new_case perm)
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Deploy"}'
  ev "$d" '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}'
  last "$d" jarvis_activity | grep -q 'Needs approval' || fail "a permission request must show Needs approval"
  last "$d" jarvis_tool | grep -q 'Needs approval: Bash' || fail "the tool line must name the tool waiting for approval"
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}'
  last "$d" jarvis_activity | grep -q 'Working: Deploy' || fail "the next tool means the approval was answered"
  : > "$d/log"
  ev "$d" '{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
  [ ! -s "$d/log" ] || fail "an idle reminder must change nothing: $(cat "$d/log")"
  pass "sidebar: Needs approval on a permission prompt, back to Working after it, idle reminders ignored"
}

test_subagents_count_and_finished_turn() {
  local d
  d=$(new_case subs)
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Research"}'
  ev "$d" '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1","agent_type":"Explore"}'
  ev "$d" '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a2","agent_type":"Explore"}'
  last "$d" jarvis_subagents | grep -q 'Subagents: 2 running' || fail "the pill must count running subagents"
  ev "$d" '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Started them."}'
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"s1","agent_id":"a1","tool_name":"Grep"}'
  ev "$d" '{"hook_event_name":"PostToolUse","session_id":"s1","agent_id":"a1","tool_name":"Grep"}'
  last "$d" jarvis_activity | grep -q 'set-status jarvis_activity Done' || fail "a subagent tool must never move a finished turn back to Working"
  ev "$d" '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a1"}'
  last "$d" jarvis_subagents | grep -q 'Subagents: 1 running' || fail "the count must drop as subagents stop"
  ev "$d" '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a2"}'
  last "$d" jarvis_subagents | grep -q '^clear-status jarvis_subagents' || fail "the pill must clear when none run"
  pass "sidebar: subagents pill counts them; their events never revive a finished turn"
}

test_ownership() {
  local d sleeper
  d=$(new_case owner)
  sleep 300 & sleeper=$!
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"main","prompt":"Main work"}' JARVIS_SIDEBAR_CLIENT_PID=$sleeper
  : > "$d/log"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"nested","prompt":"nested -p run"}' JARVIS_SIDEBAR_CLIENT_PID=$$
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"nested","tool_name":"Read"}' JARVIS_SIDEBAR_CLIENT_PID=$$
  [ ! -s "$d/log" ] || fail "a nested session must never drive the owner's tab: $(cat "$d/log")"
  ev "$d" '{"hook_event_name":"SessionStart","session_id":"cleared","source":"clear"}' JARVIS_SIDEBAR_CLIENT_PID=$sleeper
  last "$d" jarvis_activity | grep -q 'Ready' || fail "/clear in the same client must re-adopt the tab"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  : > "$d/log"
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"newer","tool_name":"Read"}' JARVIS_SIDEBAR_CLIENT_PID=$$
  [ ! -s "$d/log" ] || fail "a tool event alone must not take over a tab"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"newer","prompt":"Take over"}' JARVIS_SIDEBAR_CLIENT_PID=$$
  last "$d" jarvis_activity | grep -q 'Working: Take over' || fail "a new session must take over once the owner is gone"
  pass "sidebar: the owning client drives the tab; a nested session never does; /clear re-adopts; a gone owner is replaced"
}

test_parallel_hooks_converge() {
  local d i k des sent waited=0
  d=$(new_case parallel)
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Go"}'
  for i in 1 2 3 4 5 6 7 8; do
    printf '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/f%s"}}' "$i" \
      | env PATH="$d/bin:$PATH" SB_CASE="$d" CMUX_WORKSPACE_ID=ws1 JARVIS_SIDEBAR_STATE="$d/state" \
        JARVIS_SIDEBAR_CLIENT_PID=$$ JARVIS_SIDEBAR_GH=no-gh-here "$HB" "$HOOK" &
  done
  wait
  while [ -e "$d/state/ws1/.writer.lock" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  sleep 0.5
  for k in jarvis_activity jarvis_tool; do
    des=$(cat "$d/state/ws1/pill/$k"); sent=$(cat "$d/state/ws1/sent/$k" 2>/dev/null)
    [ "$des" = "$sent" ] || fail "$k did not converge: desired '$des' sent '$sent'"
  done
  [ "$(last "$d" jarvis_tool | sed 's/ --icon.*//')" = "set-status jarvis_tool $(cut -d $'\037' -f1 "$d/state/ws1/pill/jarvis_tool")" ] \
    || fail "the last tool line sent must be the latest desired one"
  pass "sidebar: parallel hooks converge on the latest desired pills"
}

test_failed_write_is_retried() {
  local d
  d=$(new_case retry)
  : > "$d/fail-set"
  ev "$d" '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Retry me"}'
  grep -q 'Working: Retry me' "$d/log" && fail "the fake must have refused the write"
  rm -f "$d/fail-set"
  ev "$d" '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/a"}}'
  last "$d" jarvis_activity | grep -q 'Working: Retry me' || fail "a refused write must be sent again on the next pass"
  pass "sidebar: a pill cmux refused is retried, never marked sent"
}

test_pr_and_issue_pills() {
  local d repo
  d=$(new_case refs)
  repo="$d/repo"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" remote add origin git@github.com:someone/proj.git
  git -C "$repo" checkout -q -b fix/issue-7-login
  cat > "$d/bin/fakegh" <<'SH'
#!/usr/bin/env bash
[ -f "$SB_CASE/no-pr" ] && exit 1
echo '{"number":12,"url":"https://github.com/someone/proj/pull/12","state":"OPEN","closingIssuesReferences":[{"number":9}]}'
SH
  chmod +x "$d/bin/fakegh"
  ev "$d" "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh
  last "$d" jarvis_pr | grep -q 'PR #12 open .*--url https://github.com/someone/proj/pull/12' || fail "the PR pill must come from gh: $(last "$d" jarvis_pr)"
  last "$d" jarvis_issue | grep -q 'Issue #9 .*--url https://github.com/someone/proj/issues/9' || fail "the PR's closing issue wins: $(last "$d" jarvis_issue)"
  : > "$d/no-pr"
  ev "$d" "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh JARVIS_SIDEBAR_REFS_SECS=0
  last "$d" jarvis_pr | grep -q '^clear-status jarvis_pr' || fail "no PR must clear the PR pill"
  last "$d" jarvis_issue | grep -q 'Issue #7 .*--url https://github.com/someone/proj/issues/7' || fail "without a PR the branch names the issue: $(last "$d" jarvis_issue)"
  git -C "$repo" checkout -q main
  ev "$d" "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh JARVIS_SIDEBAR_REFS_SECS=0
  last "$d" jarvis_issue | grep -q '^clear-status jarvis_issue' || fail "the default branch shows no issue pill"
  pass "sidebar: PR and issue pills from gh or the branch name, with links; none on the default branch"
}

test_refs_refresh_ignores_host_stat() {
  local d repo
  d=$(new_case refs-stat)
  repo="$d/repo"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" checkout -q -b topic
  # A stat that answers neither BSD nor GNU style, like GNU stat reading -f as
  # filesystem status: the refresh must not depend on it.
  printf '#!/usr/bin/env bash\necho "  File: weird filesystem text"\nexit 0\n' > "$d/bin/stat"
  # shellcheck disable=SC2016 # expanded by the fake gh
  printf '#!/usr/bin/env bash\n[ -f "$SB_CASE/no-pr" ] && exit 1\necho %s\n' \
    "'{\"number\":3,\"url\":\"https://github.com/o/r/pull/3\",\"state\":\"OPEN\"}'" > "$d/bin/fakegh"
  chmod +x "$d/bin/stat" "$d/bin/fakegh"
  ev "$d" "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh
  last "$d" jarvis_pr | grep -q 'PR #3 open' || fail "the PR pill must appear: $(last "$d" jarvis_pr)"
  : > "$d/no-pr"
  ev "$d" "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh JARVIS_SIDEBAR_REFS_SECS=0
  last "$d" jarvis_pr | grep -q '^clear-status jarvis_pr' || fail "the refresh must not depend on the host's stat: $(last "$d" jarvis_pr)"
  rm -f "$d/no-pr"
  : > "$d/log"
  ev "$d" "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"cwd\":\"$repo\"}" JARVIS_SIDEBAR_GH=fakegh
  ! grep -q 'jarvis_pr' "$d/log" || fail "within the refresh window the same branch must not be looked up again"
  pass "sidebar: PR refresh and its rate limit work whatever the host's stat does"
}

test_noop_outside_cmux_and_silent
test_activity_and_tool_lines
test_permission_and_notifications
test_subagents_count_and_finished_turn
test_ownership
test_parallel_hooks_converge
test_failed_write_is_retried
test_pr_and_issue_pills
test_refs_refresh_ignores_host_stat
