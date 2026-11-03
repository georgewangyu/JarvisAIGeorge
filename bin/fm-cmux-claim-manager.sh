#!/usr/bin/env bash
# bin/fm-cmux-claim-manager.sh - at session start, name, pin and color this
# home's manager tab in cmux (the Workers layout), for every harness.
#
# The layout used to rename the manager tab only when the first worker spawned
# (fm_cmux_layout_ensure), so a Codex manager kept its default title until then.
# This runs from the SessionStart hooks (.claude/settings.json, .codex/hooks.json)
# and from bin/jarvis-launch before it starts either tool. It never creates the
# Workers group (the first spawn does) and never fails a session: it exits 0
# with no output, and does nothing outside cmux, with the layout off, or when
# cmux cannot be reached.
#
# Name: config/cmux-home-name, else config/manager-name, else JarvisAIGeorge
# (a secondmate home is "Friday <n> · <charter>"); see fm_cmux_layout_home_name.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export FM_HOME="${FM_HOME:-$(dirname "$SCRIPT_DIR")}"
[ -n "${CMUX_WORKSPACE_ID:-}" ] || exit 0
(
  # shellcheck source=bin/backends/cmux.sh
  . "$SCRIPT_DIR/backends/cmux.sh" >/dev/null 2>&1 || exit 0
  fm_cmux_layout_claim_manager
) </dev/null >/dev/null 2>&1
exit 0
