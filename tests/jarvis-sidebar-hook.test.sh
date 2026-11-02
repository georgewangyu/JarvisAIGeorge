#!/usr/bin/env bash
# tests/jarvis-sidebar-hook.test.sh - the core plugin's hook config fits every
# harness's hook budget and the sidebar hook ends inside it.
#
# Codex CLI 0.166.0 clamps a SessionEnd hook timeout to 3s and warned about the
# plugin asking for 5s. hooks.json now asks for 3s on SessionEnd; Claude Code
# keeps every event it had. The hook bounds each cmux call, so even a hung cmux
# cannot hold SessionEnd past the cap. The live Codex check (no clamp warning,
# the pill cleared at exit) is verified on a personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-sidebar-hook-tests)
HOOKS="$ROOT/plugins/jarvis-ai-george/hooks/hooks.json"
HOOK="$ROOT/plugins/jarvis-ai-george/hooks/jarvis-sidebar.sh"
SESSION_END_CAP=3

test_timeouts_fit_caps() {
  python3 - "$HOOKS" "$SESSION_END_CAP" <<'PY' || fail "hooks.json timeouts or events are wrong"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
cap = int(sys.argv[2])
want = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"}
assert set(hooks) == want, f"Claude Code events must stay covered: {sorted(hooks)}"
for event, groups in hooks.items():
    for g in groups:
        for h in g["hooks"]:
            t = h.get("timeout")
            assert isinstance(t, int) and 0 < t <= 5, f"{event}: timeout {t} must be set and at most 5s"
            if event == "SessionEnd":
                assert t <= cap, f"SessionEnd timeout {t}s is over the {cap}s Codex cap"
PY
  pass "sidebar hooks: every Claude event kept, SessionEnd within the 3s Codex cap"
}

test_session_end_bounded_with_hung_cmux() {
  local bin="$TMP_ROOT/bin" start end
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$bin/cmux"
  chmod +x "$bin/cmux"
  printf 'ready' > "${TMPDIR:-/tmp}/jarvis-sidebar-$(id -u)-ws-hung"
  start=$(date +%s)
  printf '%s' '{"hook_event_name":"SessionEnd"}' \
    | PATH="$bin:$PATH" CMUX_WORKSPACE_ID=ws-hung JARVIS_SIDEBAR_CMUX_SECS=1 bash "$HOOK"
  end=$(date +%s)
  [ $((end - start)) -lt "$SESSION_END_CAP" ] || fail "SessionEnd took $((end - start))s with a hung cmux (cap ${SESSION_END_CAP}s)"
  pkill -f "$bin/cmux" 2>/dev/null || true
  pass "sidebar hooks: SessionEnd ends inside the cap even when cmux hangs"
}

test_timeouts_fit_caps
test_session_end_bounded_with_hung_cmux
