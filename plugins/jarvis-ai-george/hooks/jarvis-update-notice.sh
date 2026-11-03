#!/usr/bin/env bash
# jarvis-update-notice.sh - Claude Code (and Codex) UserPromptSubmit hook: once
# per session, tell the user a newer Jarvis plugin is installed.
#
# A plugin update installs a new version folder and marks the old one
# `.orphaned_at`; a running session keeps the old folder and its hooks. When this
# session's own folder carries that mark, print one notice for the user and
# record it, so the session shows it once. The home's bin/hook writes the same
# record for home updates, so a session sees one notice whichever side changed.
#
# Contract: never an error, always exits 0, prints only the one JSON notice.
# JARVIS_UPDATE_NOTICE=off turns it off. docs/install.md "Updates" owns the
# operator view.
set -u
exec 2>/dev/null
payload=
IFS= read -r -d '' payload || true
[ "${JARVIS_UPDATE_NOTICE:-on}" = off ] && exit 0
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
[ -e "$root/.orphaned_at" ] || exit 0
re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]{1,128})"'
[[ ${payload:0:4096} =~ $re ]] || exit 0
sid=${BASH_REMATCH[1]}
dir=${JARVIS_NOTICE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/jarvis-ai-george/update-notice}
case "$dir" in /?*) ;; *) exit 0 ;; esac
[ -e "$dir/$sid" ] && exit 0
mkdir -p "$dir" && : > "$dir/$sid" || exit 0
printf '%s\n' '{"systemMessage":"Jarvis was updated. Restart to load it."}'
exit 0
