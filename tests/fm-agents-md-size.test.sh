#!/usr/bin/env bash
# tests/fm-agents-md-size.test.sh - the always-loaded root AGENTS.md must fit
# every harness's project-document budget, and everything it moved out must
# stay reachable from it.
#
# Codex reads at most project_doc_max_bytes (default 32768) of AGENTS.md and
# truncates the rest, so the root file is held under FM_AGENTS_MD_MAX_BYTES
# (default 30000, leaving headroom). A byte budget alone does not prove the
# contract is complete, so this also checks that every docs/ file AGENTS.md
# names exists and every skill section 13 names exists in .agents/skills.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX=${FM_AGENTS_MD_MAX_BYTES:-30000}
CODEX_LIMIT=32768

test_size() {
  local bytes
  bytes=$(wc -c < "$ROOT/AGENTS.md" | tr -d ' ')
  [ "$MAX" -lt "$CODEX_LIMIT" ] || fail "budget $MAX must stay below the Codex limit $CODEX_LIMIT"
  [ "$bytes" -le "$MAX" ] || fail "AGENTS.md is $bytes bytes, over the $MAX-byte budget; move conditional detail into a skill or docs/ file and leave a one-line trigger (firstmate-coding-guidelines)"
  pass "AGENTS.md is $bytes bytes (budget $MAX, Codex limit $CODEX_LIMIT)"
}

test_moved_docs_reachable() {
  local doc missing=
  while read -r doc; do
    [ -f "$ROOT/$doc" ] || missing="$missing $doc"
  done < <(grep -o 'docs/[A-Za-z0-9._/-]*\.md' "$ROOT/AGENTS.md" | sort -u)
  [ -z "$missing" ] || fail "AGENTS.md names docs that do not exist:$missing"
  for doc in home-layout session-start-digest dispatch-routing task-lifecycle supervision-protocol captain-voice backlog-contract crewmate-briefs; do
    grep -q "docs/$doc.md" "$ROOT/AGENTS.md" || fail "AGENTS.md must keep its trigger for docs/$doc.md"
  done
  pass "every docs/ file AGENTS.md names exists, including each moved section"
}

test_trigger_skills_exist() {
  local skill missing=
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  while read -r skill; do
    [ -f "$ROOT/.agents/skills/$skill/SKILL.md" ] || missing="$missing $skill"
  done < <(sed -n '/^## 13\./,/^## 14\./p' "$ROOT/AGENTS.md" | sed -n 's/^- `\([a-z0-9-]*\)`.*/\1/p')
  [ -z "$missing" ] || fail "section 13 names skills that do not exist:$missing"
  pass "every section 13 trigger names an existing skill"
}

test_size
test_moved_docs_reachable
test_trigger_skills_exist
