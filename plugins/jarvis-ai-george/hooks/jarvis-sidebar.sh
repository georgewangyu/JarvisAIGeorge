#!/usr/bin/env bash
# jarvis-sidebar.sh - Claude Code hook: show this session's state as a cmux
# sidebar pill on its own workspace.
#
#   UserPromptSubmit, PreToolUse     -> working
#   PermissionRequest, Notification  -> needs you (permission prompt; idle reminders ignored)
#   Stop                             -> done (turn ended, waiting for the next ask)
#   SessionStart                     -> ready
#   SessionEnd                       -> pill cleared
#
# A no-op outside cmux or when the cmux CLI or socket is unavailable. Never
# blocks the session: always exits 0 with no output. One pill key ("jarvis"),
# written only when the state changes (cached per workspace under $TMPDIR).
# Codex sessions do not run hooks; the Workers board covers them by polling.
set -u
input=$(cat 2>/dev/null || true)
ws=${CMUX_WORKSPACE_ID:-}
[ -n "$ws" ] || exit 0
bin=$(command -v cmux 2>/dev/null || true)
[ -n "$bin" ] || bin=/Applications/cmux.app/Contents/Resources/bin/cmux
[ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | head -1)
# Claude's idle reminder after a finished turn is not a request for the user.
if [ "$event" = Notification ]; then
  case "$input" in *idle_prompt*|*'waiting for your input'*) exit 0 ;; esac
fi
case "$event" in
  UserPromptSubmit|PreToolUse) state=working; icon=bolt.fill; color='#3B82F6' ;;
  PermissionRequest|Notification) state='needs you'; icon=hand.raised.fill; color='#F59E0B' ;;
  Stop) state=done; icon=checkmark.circle.fill; color='#6B7280' ;;
  SessionStart) state=ready; icon=circle; color='#6B7280' ;;
  SessionEnd) state=clear ;;
  *) exit 0 ;;
esac

cache="${TMPDIR:-/tmp}/jarvis-sidebar-$(id -u)-$ws"
prev=$(cat "$cache" 2>/dev/null || true)
[ "$prev" = "$state" ] && exit 0
printf '%s' "$state" > "$cache" 2>/dev/null || true

if [ "$state" = clear ]; then
  CMUX_QUIET=1 "$bin" clear-status jarvis --workspace "$ws" >/dev/null 2>&1 || true
  rm -f "$cache" 2>/dev/null || true
else
  CMUX_QUIET=1 "$bin" set-status jarvis "$state" --icon "$icon" --color "$color" --priority 90 --workspace "$ws" >/dev/null 2>&1 || true
fi
exit 0
