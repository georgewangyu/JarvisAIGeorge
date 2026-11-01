#!/usr/bin/env bash
# tests/jarvis-manager-write-guard.test.sh - unit tests for the Jarvis manager
# write guard (bin/jarvis-manager-write-guard.sh): MCP writes are denied, reads
# and non-MCP tools pass, the word list is editable, and the guard can be off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-write-guard-tests)
GUARD="$ROOT/bin/jarvis-manager-write-guard.sh"

guard() {  # <home> <hook-json>
  printf '%s' "$2" | FM_HOME="$1" "$GUARD"
}

denies() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

test_writes_denied() {
  local h="$TMP_ROOT/default" out t
  mkdir -p "$h/config"
  for t in mcp__chat__post_message mcp__tracker__create_issue mcp__docs__update_page \
    mcp__vcs__merge_pull_request mcp__ci__deployService mcp__review__AddComment mcp__x__ResolveThread; do
    out=$(guard "$h" "{\"tool_name\":\"$t\",\"tool_input\":{}}")
    denies "$out" || fail "$t must be denied: got '$out'"
  done
  out=$(guard "$h" '{"tool_name":"mcp__tickets__TicketActions","tool_input":{"action":"update-comment","id":"1"}}')
  denies "$out" || fail "a write action field must be denied: got '$out'"
  printf '%s' "$out" | grep -q "Dispatch a worker" || fail "deny reason must tell the manager to dispatch"
  pass "write guard: MCP writes by name or action field are denied with a dispatch hint"
}

test_reads_allowed() {
  local h="$TMP_ROOT/default" out t
  for t in mcp__chat__get_messages mcp__chat__list_comments mcp__docs__search mcp__docs__read_page \
    mcp__deploy-tools__describe_service mcp__tickets__TicketReadActions; do
    out=$(guard "$h" "{\"tool_name\":\"$t\",\"tool_input\":{\"query\":\"post a comment\"}}")
    [ -z "$out" ] || fail "$t must be allowed: got '$out'"
  done
  out=$(guard "$h" '{"tool_name":"mcp__tickets__TicketActions","tool_input":{"action":"get-comments"}}')
  [ -z "$out" ] || fail "a read action must be allowed: got '$out'"
  out=$(guard "$h" '{"tool_name":"Bash","tool_input":{"command":"git push"}}')
  [ -z "$out" ] || fail "non-MCP tools are out of scope: got '$out'"
  pass "write guard: reads, searches, server names and non-MCP tools pass"
}

test_word_list_editable() {
  local h="$TMP_ROOT/custom" out
  mkdir -p "$h/config"
  printf '# only these\nlaunch\n' > "$h/config/manager-write-words"
  out=$(guard "$h" '{"tool_name":"mcp__rocket__launch_now","tool_input":{}}')
  denies "$out" || fail "a configured word must be denied: got '$out'"
  out=$(guard "$h" '{"tool_name":"mcp__chat__post_message","tool_input":{}}')
  [ -z "$out" ] || fail "a word off the configured list must pass: got '$out'"
  : > "$h/config/manager-write-words"
  out=$(guard "$h" '{"tool_name":"mcp__rocket__launch_now","tool_input":{}}')
  [ -z "$out" ] || fail "an empty list must disable the guard: got '$out'"
  out=$(printf '%s' '{"tool_name":"mcp__chat__post_message"}' | FM_HOME="$TMP_ROOT/default" JARVIS_MANAGER_WRITE_GUARD=off "$GUARD")
  [ -z "$out" ] || fail "JARVIS_MANAGER_WRITE_GUARD=off must disable the guard: got '$out'"
  pass "write guard: config/manager-write-words replaces the list; empty or off disables"
}

test_writes_denied
test_reads_allowed
test_word_list_editable
