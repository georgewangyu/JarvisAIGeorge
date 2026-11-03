#!/usr/bin/env bash
# tests/jarvis-new-extension.test.sh - extensions are offered from their
# manifests, and an extension that arrives with an update is offered once.
#
# The offer list is built from the vendored manifests (id, one-line summary,
# optional `recommended: true`), never a hardcoded list. Each extension gets one
# recorded decision (installed, declined, later). A known extension without one
# prints JARVIS_NEW_EXTENSION at session start; installing records it, declining
# keeps it quiet, "later" re-offers after 14 days. One code path for both tools:
# Claude refreshes with `plugin marketplace update` and installs with `plugin
# install`; Codex refreshes with `plugin marketplace upgrade` and installs with
# `plugin add`. Both CLIs are stubs; the live Codex run is verified on a
# personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-new-extension-tests)
export JARVIS_HOME_POINTER="$TMP_ROOT/home-pointer"
SETUP="$ROOT/bin/jarvis-setup.sh"
CODEX=co""dex

make_stub() {  # <dir> <name>
  mkdir -p "$1"
  cat > "$1/$2" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/$2.calls"
exit 0
STUB
  chmod +x "$1/$2"
}

synthetic() {  # <dir>: a new extension that arrived with an update
  cat > "$1/video-agent.json" <<'EOF'
{"schema": 1, "id": "video-agent", "name": "VideoAgent", "version": "0.1.0",
 "summary": "cuts and captions videos",
 "description": "Video agent. It edits video.", "repo": "example/VideoAgent",
 "agents": [{"name": "editor", "summary": "edits a video", "dispatch_when": "a video needs editing"}],
 "skills": [], "relies_on_core": [], "requires": []}
EOF
}

ext_dir() {  # <dir>: the shipped manifests plus nothing else
  mkdir -p "$1"
  cp "$ROOT"/plugins/jarvis-ai-george/extensions/*.json "$1/"
}

setup() {  # <harness> <home> <tool-home> <bin> <ext> <args...>
  local hn=$1 h=$2 t=$3 b=$4 e=$5
  shift 5
  PATH="$b:$PATH" JARVIS_HARNESS="$hn" FM_HOME="$h" CLAUDE_CONFIG_DIR="$t" CODEX_HOME="$t" \
    JARVIS_EXTENSIONS_DIR="$e" "$SETUP" "$@"
}

test_first_run_offer_from_manifests() {
  local e="$TMP_ROOT/first-ext" h="$TMP_ROOT/first" out
  ext_dir "$e"
  synthetic "$e"
  python3 - "$e/video-agent.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["recommended"] = True
open(sys.argv[1], "w").write(json.dumps(m))
PY
  out=$(setup claude "$h" "$TMP_ROOT/first-claude" "$TMP_ROOT/none" "$e" detect)
  assert_contains "$out" "extensions not chosen (offer: george-coding-agent (" "first run offers the shipped extension"
  assert_contains "$out" "video-agent (cuts and captions videos, recommended)" "first run offers a manifest's summary and recommended flag"
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION" "a first run is one setup line, not new-extension lines"
  out=$(setup claude "$h" "$TMP_ROOT/first-claude" "$TMP_ROOT/none" "$e" status)
  assert_contains "$out" "video-agent (cuts and captions videos, recommended)" "status names the offer too"
  pass "first run: the offer list comes from the manifests with summary and recommended"
}

test_new_extension_once() {  # <harness>
  local hn=$1 e="$TMP_ROOT/$1-ext" h="$TMP_ROOT/$1-home" t="$TMP_ROOT/$1-tool" b="$TMP_ROOT/$1-bin" out n calls
  ext_dir "$e"
  if [ "$hn" = claude ]; then make_stub "$b" claude; else make_stub "$b" "$CODEX"; fi
  setup "$hn" "$h" "$t" "$b" "$e" extensions george-coding-agent >/dev/null || fail "$hn: first install"
  out=$(setup "$hn" "$h" "$t" "$b" "$e" detect)
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION" "$hn: nothing new before the update"

  synthetic "$e"
  out=$(setup "$hn" "$h" "$t" "$b" "$e" detect)
  n=$(printf '%s\n' "$out" | grep -c '^JARVIS_NEW_EXTENSION: video-agent (cuts and captions videos)')
  assert_equals 1 "$n" "$hn: the new extension is offered exactly once in the session start output"
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION: george-coding-agent" "$hn: a decided extension is not offered"

  : > "$b/$([ "$hn" = claude ] && echo claude || echo "$CODEX").calls"
  setup "$hn" "$h" "$t" "$b" "$e" extensions video-agent >/dev/null || fail "$hn: installing the new extension"
  calls=$(cat "$b"/*.calls)
  if [ "$hn" = claude ]; then
    assert_contains "$calls" "plugin marketplace update jarvis-ai-george" "claude: refreshes the marketplace first"
    assert_contains "$calls" "plugin install video-agent@jarvis-ai-george --scope user" "claude: installs with plugin install"
  else
    assert_contains "$calls" "plugin marketplace upgrade jarvis-ai-george" "codex: refreshes the marketplace first"
    assert_contains "$calls" "plugin add video-agent@jarvis-ai-george" "codex: installs with plugin add"
  fi
  assert_grep "video-agent installed" "$h/config/extension-decisions" "$hn: install records the decision"
  out=$(setup "$hn" "$h" "$t" "$b" "$e" detect)
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION" "$hn: an installed extension is not offered again"
  pass "$hn: a new extension is offered once, installs through the tool's own CLI, and is recorded"
}

test_decline_and_later() {
  local e="$TMP_ROOT/dec-ext" h="$TMP_ROOT/dec-home" t="$TMP_ROOT/dec-tool" b="$TMP_ROOT/none" out
  ext_dir "$e"
  synthetic "$e"
  setup claude "$h" "$t" "$b" "$e" extensions decline george-coding-agent >/dev/null
  out=$(setup claude "$h" "$t" "$b" "$e" detect)
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent" "an undecided extension is offered"
  setup claude "$h" "$t" "$b" "$e" extensions decline video-agent >/dev/null
  out=$(setup claude "$h" "$t" "$b" "$e" detect)
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION" "a declined extension stays quiet"
  setup claude "$h" "$t" "$b" "$e" extensions later video-agent >/dev/null
  out=$(setup claude "$h" "$t" "$b" "$e" detect)
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION" "later stays quiet within 14 days"
  sed -i.bak 's/^video-agent later .*/video-agent later 1000/' "$h/config/extension-decisions" && rm -f "$h/config/extension-decisions.bak"
  out=$(setup claude "$h" "$t" "$b" "$e" detect)
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent" "later re-offers after 14 days"
  setup claude "$h" "$t" "$b" "$e" extensions decline bogus >/dev/null 2>&1 && fail "an unknown id is refused"
  out=$(setup claude "$h" "$t" "$b" "$e" extensions list)
  assert_contains "$out" "george-coding-agent declined" "list shows each decision"
  pass "decline stays quiet, later re-offers after 14 days, list shows decisions"
}

test_legacy_choice_counts() {
  local e="$TMP_ROOT/leg-ext" h="$TMP_ROOT/leg-home" out
  ext_dir "$e"
  synthetic "$e"
  mkdir -p "$h/config"
  echo none > "$h/config/extensions"
  out=$(setup claude "$h" "$TMP_ROOT/leg-tool" "$TMP_ROOT/none" "$e" detect)
  assert_not_contains "$out" "extensions not chosen" "an older home's choice still counts"
  assert_not_contains "$out" "JARVIS_NEW_EXTENSION: george-coding-agent" "an older none still declines the coding extension"
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent" "an older none does not decline an extension that did not exist then"
  pass "an older config/extensions keeps its meaning; later extensions are still offered"
}

# Both session-start paths reach the line: the Claude settings hook and the
# Codex hooks.json hook (and Codex's AGENTS.md fallback runs the same detect).
test_session_start_paths() {
  local e="$TMP_ROOT/ss-ext" h="$TMP_ROOT/ss-home" t="$TMP_ROOT/ss-tool" cmd out
  ext_dir "$e"
  synthetic "$e"
  mkdir -p "$h/config"
  echo "george-coding-agent declined" > "$h/config/extension-decisions"
  cmd=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("jarvis-setup.sh"))][0]' "$ROOT/.claude/settings.json")
  out=$(printf '{"session_id":"x1","hook_event_name":"SessionStart","source":"startup"}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$ROOT" FM_HOME="$h" CLAUDE_CONFIG_DIR="$t" \
      JARVIS_EXTENSIONS_DIR="$e" JARVIS_HARNESS=claude sh -c "$cmd")
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent" "the Claude SessionStart hook prints the line"
  cmd=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("jarvis-setup.sh"))][0]' "$ROOT/.codex/hooks.json")
  out=$(printf '{"session_id":"x2","hook_event_name":"SessionStart","source":"startup"}' \
    | (cd "$ROOT" && FM_HOME="$h" CODEX_HOME="$t" JARVIS_EXTENSIONS_DIR="$e" sh -c "$cmd"))
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent" "the Codex SessionStart hook prints the line"
  grep -q 'JARVIS_NEW_EXTENSION' "$ROOT/AGENTS.md" || fail "the AGENTS.md fallback names the line for Codex without trusted hooks"
  grep -q 'JARVIS_NEW_EXTENSION' "$ROOT/plugins/jarvis-ai-george/skills/role-jarvis/SKILL.md" || fail "role-jarvis tells the manager what to do with it"
  pass "the line reaches both tools' session start, and both manager surfaces handle it"
}

# Publisher side: a new peer manifest, rebuilt, lands in the catalog and is offered.
test_rebuild_lists_and_offers() {
  local repo="$TMP_ROOT/rebuild" out h="$TMP_ROOT/rebuild-home"
  fm_git_identity
  mkdir -p "$repo"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$repo"
  synthetic "$repo/plugins/jarvis-ai-george/extensions"
  (cd "$repo" && python3 tools/jarvis-build.py --base "" >/dev/null) || fail "rebuild with a new peer"
  grep -q 'video-agent' "$repo/plugins/jarvis-ai-george/skills/extension-catalog/SKILL.md" || fail "the catalog lists the new extension"
  mkdir -p "$h/config"
  echo "george-coding-agent installed" > "$h/config/extension-decisions"
  out=$(JARVIS_HARNESS=claude FM_HOME="$h" CLAUDE_CONFIG_DIR="$TMP_ROOT/rebuild-tool" "$repo/bin/jarvis-setup.sh" detect)
  assert_contains "$out" "JARVIS_NEW_EXTENSION: video-agent (cuts and captions videos)" "the rebuilt home offers it"
  pass "publisher: add the manifest, rebuild, the catalog lists it and homes offer it once"
}

test_first_run_offer_from_manifests
test_new_extension_once claude
test_new_extension_once "$CODEX"
test_decline_and_later
test_legacy_choice_counts
test_session_start_paths
test_rebuild_lists_and_offers
