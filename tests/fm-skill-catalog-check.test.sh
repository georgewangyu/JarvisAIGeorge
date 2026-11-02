#!/usr/bin/env bash
# shellcheck disable=SC2016  # the captures quote literal $skill mentions
# tests/fm-skill-catalog-check.test.sh - synthetic startup captures for
# bin/fm-skill-catalog-check.sh: a skills-budget warning panel is reported as an
# incomplete catalog, a normal startup and the separate project-document
# truncation notice are not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-skill-catalog-check.sh"

test_overflow_panel_reported() {
  local out
  out=$(printf '%s\n' \
    '╭ Warning ─────────────────────────────────────────╮' \
    '│ Skills context budget exceeded: all skill        │' \
    '│ descriptions were removed and 73 additional      │' \
    '│ skills were omitted from the list.               │' \
    '╰──────────────────────────────────────────────────╯' \
    '› Load $role-coding first' | "$CHECK")
  printf '%s' "$out" | grep -q '^SKILL_CATALOG_INCOMPLETE: ' || fail "an overflow panel must be reported: '$out'"
  printf '%s' "$out" | grep -qi 'budget exceeded' || fail "the report must quote the budget wording: '$out'"
  printf '%s' "$out" | grep -q '73 additional skills were omitted' || fail "the report must quote the omitted count: '$out'"
  printf '%s' "$out" | grep -q 'role-<agent>' || fail "the report must name the explicit-load remedy"
  pass "skill catalog check: a wrapped Codex overflow panel is reported with its counts and the remedy"
}

test_clean_startup_silent() {
  local out
  out=$(printf '%s\n' 'OpenAI Codex (v0.166.0)' 'model: gpt-5 high' '› Load $role-coding first' 'Working (3s)' | "$CHECK")
  [ -z "$out" ] || fail "a clean startup must print nothing: '$out'"
  pass "skill catalog check: a clean startup prints nothing"
}

test_project_doc_truncation_is_separate() {
  local out
  out=$(printf '%s\n' 'project doc AGENTS.md truncated: 32768 bytes remaining of 85554' 'skills loaded from .agents/skills' | "$CHECK")
  [ -z "$out" ] || fail "the project-document byte limit is a different diagnostic: '$out'"
  pass "skill catalog check: project-document truncation is not reported as a catalog gap"
}

test_file_input_and_exit_status() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/fm-catalog.XXXXXX")
  printf 'all skill descriptions were removed\n' > "$f"
  "$CHECK" "$f" | grep -q '^SKILL_CATALOG_INCOMPLETE: ' || fail "file input must be classified"
  rm -f "$f"
  "$CHECK" /nonexistent/capture >/dev/null 2>&1
  [ $? -eq 2 ] || fail "an unreadable capture must exit 2"
  pass "skill catalog check: reads a file and exits 2 only on unreadable input"
}

test_overflow_panel_reported
test_clean_startup_silent
test_project_doc_truncation_is_separate
test_file_input_and_exit_status
