#!/usr/bin/env bash
# jarvis-home.sh - the one resolver for "which JarvisAIGeorge home is this
# session's fleet". Shipped in the core plugin so every install has it; the home
# carries bin/jarvis-home.sh as a thin wrapper. Used by bin/jarvis-launch,
# bin/jarvis-setup.sh, the core plugin's SessionStart hook, and the manager role
# (role-jarvis), so a manager started in any folder by any tool finds its fleet.
#
# Order:
#   1. JARVIS_HOME, when set (an explicit choice, so two clones can coexist);
#      a value that is not a home is an error, never skipped.
#   2. The pointer file setup records once and refreshes on every setup run:
#      ${JARVIS_HOME_POINTER:-${XDG_CONFIG_HOME:-$HOME/.config}/jarvis-ai-george/home}
#   3. The current folder, or its git top level, when it is itself a home.
# A home is a directory with AGENTS.md, bin/jarvis-setup.sh and bin/fm-spawn.sh.
# FM_HOME follows the resolved home unless it is already set (a secondmate home).
#
# Usage:
#   jarvis-home.sh                 print the home; exit 1 with "No Jarvis home
#                                  found: ..." and the fix on stderr
#   jarvis-home.sh --env           print export lines for JARVIS_HOME and FM_HOME
#   jarvis-home.sh --source        print which rule resolved it (env|pointer|cwd)
#   jarvis-home.sh --hook          SessionStart hook: on success append the
#                                  exports to $CLAUDE_ENV_FILE when set; silent
#                                  and exit 0 either way (the role reports a miss)
#   jarvis-home.sh --record <dir>  validate <dir> and write it to the pointer file
#   jarvis-home.sh --pointer       print the pointer file path
#
# It never takes a lock, starts a session or changes a fleet: resolving is read
# only, and the session lock still decides who manages a home.

set -u

POINTER="${JARVIS_HOME_POINTER:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/jarvis-ai-george/home}"

is_home() {  # <dir>
  [ -n "$1" ] && [ -f "$1/AGENTS.md" ] && [ -x "$1/bin/jarvis-setup.sh" ] && [ -x "$1/bin/fm-spawn.sh" ]
}

abs() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

FIX="Fix: start the manager with your jarvis shortcut or <home>/bin/jarvis-launch (--claude or --codex) from this folder, or run <home>/bin/jarvis-setup.sh record-home once so any folder finds it (<home> is your JarvisAIGeorge clone, default ~/jarvis)."

resolve() {  # sets HOME_DIR and SOURCE, or MISS
  local p top
  HOME_DIR=; SOURCE=; MISS=
  if [ -n "${JARVIS_HOME:-}" ]; then
    if is_home "$JARVIS_HOME"; then HOME_DIR=$(abs "$JARVIS_HOME"); SOURCE=env; return 0; fi
    MISS="JARVIS_HOME is set to '$JARVIS_HOME', which is not a JarvisAIGeorge home"
    return 1
  fi
  if [ -f "$POINTER" ]; then
    IFS= read -r p < "$POINTER" || true
    if is_home "$p"; then HOME_DIR=$(abs "$p"); SOURCE=pointer; return 0; fi
    MISS="the home pointer $POINTER names '${p:-nothing}', which no longer exists or is not a JarvisAIGeorge home"
  fi
  if is_home "$PWD"; then HOME_DIR=$(abs "$PWD"); SOURCE=cwd; return 0; fi
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
  if [ -n "$top" ] && is_home "$top"; then HOME_DIR=$(abs "$top"); SOURCE=cwd; return 0; fi
  [ -n "$MISS" ] || MISS="no JARVIS_HOME, no home pointer at $POINTER, and this folder is not a JarvisAIGeorge home"
  return 1
}

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "${1:-}" in
  ''|--path)
    resolve || { echo "No Jarvis home found: $MISS. $FIX" >&2; exit 1; }
    printf '%s\n' "$HOME_DIR"
    ;;
  --source)
    resolve || { echo "No Jarvis home found: $MISS. $FIX" >&2; exit 1; }
    printf '%s\n' "$SOURCE"
    ;;
  --env)
    resolve || { echo "No Jarvis home found: $MISS. $FIX" >&2; exit 1; }
    printf 'export JARVIS_HOME=%s\n' "$(sq "$HOME_DIR")"
    printf 'export FM_HOME=%s\n' "$(sq "${FM_HOME:-$HOME_DIR}")"
    ;;
  --hook)
    cat >/dev/null 2>&1 || true
    if resolve && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      {
        printf 'export JARVIS_HOME=%s\n' "$(sq "$HOME_DIR")"
        printf 'export FM_HOME=%s\n' "$(sq "${FM_HOME:-$HOME_DIR}")"
      } >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
    fi
    exit 0
    ;;
  --record)
    [ -n "${2:-}" ] || { echo "usage: jarvis-home.sh --record <dir>" >&2; exit 2; }
    is_home "$2" || { echo "jarvis-home: '$2' is not a JarvisAIGeorge home" >&2; exit 1; }
    mkdir -p "$(dirname "$POINTER")" || exit 1
    abs "$2" > "$POINTER.tmp.$$" && mv "$POINTER.tmp.$$" "$POINTER" || exit 1
    printf 'ok: home pointer %s -> %s\n' "$POINTER" "$(abs "$2")"
    ;;
  --pointer)
    printf '%s\n' "$POINTER"
    ;;
  *)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
