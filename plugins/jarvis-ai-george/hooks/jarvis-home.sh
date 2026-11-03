#!/usr/bin/env bash
# jarvis-home.sh - find the JarvisAIGeorge home (the clone that holds the fleet)
# from any folder. The one resolver: the home's bin/jarvis-home, bin/jarvis-setup.sh,
# the manager's instructions (Claude Code and Codex) and this plugin's
# SessionStart hook all use this file.
#
# Usage:
#   jarvis-home.sh resolve      print the home's absolute path and exit 0, or
#                               print why none was found on stderr and exit 1
#   jarvis-home.sh env          print `export JARVIS_HOME=... FM_HOME=...` lines
#                               (FM_HOME kept when already set), or exit 1
#   jarvis-home.sh pointer      print the pointer file path
#   jarvis-home.sh hook         SessionStart hook (Claude Code, manager only)
#
# Order: JARVIS_HOME when set (it must be a home, else that is the error), then
# the pointer file ${XDG_CONFIG_HOME:-~/.config}/jarvis-ai-george/home (the
# clone's absolute path, written by bin/jarvis-setup.sh; JARVIS_HOME_POINTER
# overrides its path, for tests), then the current
# folder if it is a home. A home is a folder with bin/jarvis-setup.sh and
# AGENTS.md. A stale pointer (its clone was deleted or moved) is an error, never
# a silent fall-through to another home, so two clones only switch when one is
# chosen explicitly (JARVIS_HOME, or `bin/jarvis-setup.sh home` in the clone).
#
# Hook: only for the manager agent (payload agent_type jarvis-ai-george). Inside
# a home it is quiet (that home's own hooks run). Elsewhere it exports
# JARVIS_HOME and FM_HOME into the session (CLAUDE_ENV_FILE) and tells the
# manager to run the home's session start, which refuses another manager's
# lock; or, when no home resolves, says "No Jarvis home found" with the fix, so
# the manager never acts ready without a fleet. Always exits 0.
set -u

pointer_file() {
  if [ -n "${JARVIS_HOME_POINTER:-}" ]; then printf '%s' "$JARVIS_HOME_POINTER"; return; fi
  printf '%s/jarvis-ai-george/home' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

is_home() { [ -n "${1:-}" ] && [ -f "$1/bin/jarvis-setup.sh" ] && [ -f "$1/AGENTS.md" ]; }

FIX="Fix: in your JarvisAIGeorge clone run bin/jarvis-setup.sh home (records it in $(pointer_file)), or set JARVIS_HOME to the clone, or start with the jarvis-launch shortcut (docs/install.md \"Launch shortcut\")."

# Sets RESOLVED (the home) and VIA (env, pointer or cwd); the reason goes to stderr.
VIA=
RESOLVED=
resolve() {
  local p=""
  if [ -n "${JARVIS_HOME:-}" ]; then
    if is_home "$JARVIS_HOME"; then VIA="env"; RESOLVED=$(cd "$JARVIS_HOME" && pwd -P); return 0; fi
    echo "No Jarvis home found: JARVIS_HOME=$JARVIS_HOME is not a JarvisAIGeorge home. $FIX" >&2
    return 1
  fi
  if [ -f "$(pointer_file)" ]; then
    IFS= read -r p < "$(pointer_file)" || true
    if is_home "$p"; then VIA=pointer; RESOLVED=$(cd "$p" && pwd -P); return 0; fi
    echo "No Jarvis home found: the pointer $(pointer_file) names ${p:-nothing}, which is not a JarvisAIGeorge home (deleted or moved?). $FIX" >&2
    return 1
  fi
  if is_home "$PWD"; then VIA=cwd; RESOLVED=$(pwd -P); return 0; fi
  echo "No Jarvis home found (no JARVIS_HOME, no $(pointer_file), and $PWD is not a home). $FIX" >&2
  return 1
}

case "${1:-resolve}" in
  resolve) resolve && printf '%s\n' "$RESOLVED" ;;
  pointer) pointer_file; echo ;;
  env)
    resolve || exit 1
    h=$RESOLVED
    printf 'export JARVIS_HOME=%q\n' "$h"
    printf 'export FM_HOME=%q\n' "${FM_HOME:-$h}" ;;
  hook)
    exec 2>/dev/null
    payload=
    IFS= read -r -d '' payload || true
    re='"agent_type"[[:space:]]*:[[:space:]]*"(jarvis-ai-george:)?jarvis-ai-george"'
    [[ ${payload:0:4096} =~ $re ]] || exit 0
    here=${CLAUDE_PROJECT_DIR:-$PWD}
    is_home "$here" && exit 0
    if resolve 2>/dev/null; then
      h=$RESOLVED
      if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
        { printf 'export JARVIS_HOME=%q\n' "$h"; printf 'export FM_HOME=%q\n' "${FM_HOME:-$h}"; } >> "$CLAUDE_ENV_FILE"
      fi
      echo "JARVIS_HOME: $h (found from $VIA; exported as JARVIS_HOME and FM_HOME for this session's commands). This session was started without the jarvis-launch shortcut, so the home's session start did not run: run $h/bin/fm-session-start.sh once now (FM_HOME=$h), then follow \"Started from another folder\". If it refuses the session lock, stay read-only."
    else
      why=$(resolve 2>&1 >/dev/null)
      echo "JARVIS_NO_HOME: $why Your first reply must say \"No Jarvis home found\" with that fix. Until a home is found, do not act as if a fleet is ready: no workers, no fleet commands."
    fi
    exit 0 ;;
  *) echo "usage: jarvis-home.sh resolve|env|pointer|hook" >&2; exit 2 ;;
esac
