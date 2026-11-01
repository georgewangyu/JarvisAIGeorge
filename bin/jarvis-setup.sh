#!/usr/bin/env bash
# bin/jarvis-setup.sh - first-run setup and startup update check for a
# JarvisAIGeorge home (a clone of this repo). docs/install.md owns the
# operator flow; the jarvis-ai-george agent's "First-time setup" section owns
# how the manager walks the user through it.
#
# Usage:
#   bin/jarvis-setup.sh detect          SessionStart hook: fast, read-only, local.
#                                       Prints one JARVIS_FIRST_RUN: line when
#                                       anything is missing, nothing otherwise.
#   bin/jarvis-setup.sh status          one line per item: ok or MISSING with the fix
#   bin/jarvis-setup.sh backend cmux|tmux|auto
#                                       record the session backend choice:
#                                       cmux writes config/backend=cmux and
#                                       config/cmux-layout=workers (manager tab,
#                                       Workers group, board); tmux writes
#                                       config/backend=tmux; auto leaves the
#                                       backend to runtime detection
#   bin/jarvis-setup.sh plugins         add this repo's plugin marketplace and
#                                       install the core plugin (fallback when
#                                       folder trust did not load it; run only
#                                       after the user approves)
#   bin/jarvis-setup.sh extensions <id>...|none
#                                       install the extensions the user approved
#                                       (recommended: george-coding-agent) and
#                                       record the choice in config/extensions
#   bin/jarvis-setup.sh cmux-check      verify the cmux control socket answers
#   bin/jarvis-setup.sh update-check    bounded network check: is the home behind
#                                       origin, is plugin auto-update on. Quiet
#                                       when current. Off: config/update-check=off
#   bin/jarvis-setup.sh plugin-autoupdate on|off
#                                       let Claude Code update the marketplace and
#                                       its plugins at startup (written to the
#                                       home's .claude/settings.local.json)
#
# Nothing here installs software on its own: detect, status and update-check
# only read; every other verb is run by the manager after the user approves.
# Lines that need action start with JARVIS_FIRST_RUN:, JARVIS_SETUP: or
# JARVIS_UPDATE: and name docs/install.md for help.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
HOME_DIR="${FM_HOME:-$ROOT}"
CONFIG="$HOME_DIR/config"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKET=jarvis-ai-george
PLUGINS="jarvis-ai-george"
# Known extensions offered at first run; the user picks, nothing installs on its own.
EXTENSIONS="george-coding-agent"
DOC="docs/install.md"

die() { echo "jarvis-setup: $*" >&2; exit 2; }

backend_choice() {  # prints cmux|tmux|auto|unset
  if [ -f "$CONFIG/backend" ]; then
    tr -d '[:space:]' < "$CONFIG/backend"
  elif [ -f "$CONFIG/jarvis-backend" ]; then
    tr -d '[:space:]' < "$CONFIG/jarvis-backend"
  else
    printf unset
  fi
}

# Folder trust loads an enabled same-repo plugin into the cache without an
# installed_plugins.json entry, so either counts.
plugin_installed() {  # <plugin>
  local f="$CLAUDE_DIR/plugins/installed_plugins.json"
  { [ -f "$f" ] && grep -q "\"$1@$MARKET\"" "$f"; } \
    || [ -d "$CLAUDE_DIR/plugins/cache/$MARKET/$1" ]
}

extensions_chosen() { [ -f "$CONFIG/extensions" ]; }

missing_extensions() {
  local p out=
  for p in $EXTENSIONS; do
    plugin_installed "$p" || out="$out $p"
  done
  printf '%s' "${out# }"
}

missing_plugins() {
  local p out=
  for p in $PLUGINS; do
    plugin_installed "$p" || out="$out $p"
  done
  printf '%s' "${out# }"
}

# FirstMate's own detect-only bootstrap owns the toolchain list for the chosen
# backend; reuse it (about a second, local only) instead of a second copy.
missing_tools() {
  FM_HOME="$HOME_DIR" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK_PHASE=skip \
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>/dev/null \
    | sed -n -e 's/^MISSING: \([^ ]*\) .*/\1/p' -e 's/^MISSING_MANUAL: \([^ ]*\) .*/\1/p' \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

cmux_state() {  # ok|denied|unauth|down|error|absent
  command -v cmux >/dev/null 2>&1 || { printf absent; return; }
  local out
  out=$(cmux ping 2>&1 </dev/null)
  case "$out" in
    PONG) printf ok ;;
    *'only processes started inside cmux'*) printf denied ;;
    *'Password mode'*|*'Authentication required'*|*'Invalid password'*) printf unauth ;;
    *'Socket not found'*) printf down ;;
    *) printf error ;;
  esac
}

cmd_detect() {
  local gaps=() b p t c
  b=$(backend_choice)
  [ "$b" = unset ] && gaps+=("backend choice (cmux tabs or not)")
  p=$(missing_plugins)
  [ -n "$p" ] && gaps+=("plugins: $p")
  extensions_chosen || gaps+=("extensions not chosen (offer: $EXTENSIONS)")
  t=$(missing_tools)
  [ -n "$t" ] && gaps+=("tools: $t")
  if [ "$b" = cmux ]; then
    c=$(cmux_state)
    [ "$c" != ok ] && [ "$c" != absent ] && gaps+=("cmux socket ($c)")
  fi
  [ "${#gaps[@]}" -eq 0 ] && return 0
  local joined g
  joined=
  for g in "${gaps[@]}"; do joined="${joined:+$joined; }$g"; done
  echo "JARVIS_FIRST_RUN: setup is incomplete ($joined). Run first-time setup now: follow the \"First-time setup\" section of your instructions, starting with bin/jarvis-setup.sh status. Ask before every install. Help: $DOC"
}

cmd_status() {
  local b p t c
  b=$(backend_choice)
  if [ "$b" = unset ]; then
    echo "JARVIS_SETUP: MISSING backend choice (ask the user: use cmux tabs? then bin/jarvis-setup.sh backend cmux|tmux|auto)"
  else
    echo "ok: backend $b"
  fi
  p=$(missing_plugins)
  if [ -n "$p" ]; then
    echo "JARVIS_SETUP: MISSING plugins $p (fix after approval: bin/jarvis-setup.sh plugins; help: $DOC#plugins-did-not-install)"
  else
    echo "ok: plugins $PLUGINS"
  fi
  local e
  e=$(missing_extensions)
  if ! extensions_chosen; then
    echo "JARVIS_SETUP: MISSING extension choice. Ask which to install (recommended: george-coding-agent, the coding worker, reviewer, planning and review skills); after a yes run bin/jarvis-setup.sh extensions george-coding-agent, or extensions none"
  elif [ -n "$e" ]; then
    echo "info: extensions not installed: $e (offer when work needs one: bin/jarvis-setup.sh extensions <id>)"
  else
    echo "ok: extensions $EXTENSIONS"
  fi
  t=$(missing_tools)
  if [ -n "$t" ]; then
    echo "JARVIS_SETUP: MISSING tools $t (fix after approval: the install commands in the session-start MISSING: lines; help: $DOC#toolchain-approval)"
  else
    echo "ok: toolchain"
  fi
  if [ "$b" = cmux ]; then
    c=$(cmux_state)
    case "$c" in
      ok) echo "ok: cmux socket" ;;
      absent) echo "JARVIS_SETUP: MISSING cmux app (fix after approval: brew install --cask cmux; help: $DOC#cmux)" ;;
      *) echo "JARVIS_SETUP: MISSING cmux socket access ($c). Manual step for the user: cmux Settings > Automation > Socket Control Mode: Automation, then bin/jarvis-setup.sh cmux-check (help: $DOC#cmux-socket-mode)" ;;
    esac
  fi
}

cmd_backend() {
  mkdir -p "$CONFIG"
  case "${1:-}" in
    cmux)
      echo cmux > "$CONFIG/backend"
      echo workers > "$CONFIG/cmux-layout"
      rm -f "$CONFIG/jarvis-backend" ;;
    tmux)
      echo tmux > "$CONFIG/backend"
      rm -f "$CONFIG/cmux-layout" "$CONFIG/jarvis-backend" ;;
    auto)
      rm -f "$CONFIG/backend" "$CONFIG/cmux-layout"
      echo auto > "$CONFIG/jarvis-backend" ;;
    *) die "usage: backend cmux|tmux|auto" ;;
  esac
  echo "ok: backend $(backend_choice)"
}

marketplace_source() {
  local url
  url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
  case "$url" in
    https://github.com/*|git@github.com:*)
      url=${url#https://github.com/}; url=${url#git@github.com:}; printf '%s' "${url%.git}" ;;
    *) printf '%s' "$ROOT" ;;
  esac
}

cmd_plugins() {
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  local src p
  src=$(marketplace_source)
  if ! claude plugin marketplace list 2>/dev/null | grep -q "$MARKET"; then
    claude plugin marketplace add "$src" || die "marketplace add $src failed (help: $DOC#plugins-did-not-install)"
  fi
  for p in $PLUGINS; do
    plugin_installed "$p" || claude plugin install "$p@$MARKET" --scope user \
      || die "plugin install $p failed (help: $DOC#plugins-did-not-install)"
  done
  echo "ok: plugins $PLUGINS (restart claude in this folder to load them)"
}

cmd_extensions() {
  [ "$#" -gt 0 ] || die "usage: extensions <id>...|none"
  mkdir -p "$CONFIG"
  if [ "$1" = none ]; then
    echo none > "$CONFIG/extensions"
    echo "ok: no extensions (install one later with bin/jarvis-setup.sh extensions <id>)"
    return 0
  fi
  command -v claude >/dev/null 2>&1 || die "claude is not on PATH"
  local id
  for id in "$@"; do
    case " $EXTENSIONS " in *" $id "*) ;; *) die "unknown extension '$id' (known: $EXTENSIONS)" ;; esac
    if ! claude plugin marketplace list 2>/dev/null | grep -q "$MARKET"; then
      claude plugin marketplace add "$(marketplace_source)" || die "marketplace add failed (help: $DOC#plugins-did-not-install)"
    fi
    plugin_installed "$id" || claude plugin install "$id@$MARKET" --scope user \
      || die "plugin install $id failed (help: $DOC#plugins-did-not-install)"
    grep -qx "$id" "$CONFIG/extensions" 2>/dev/null || echo "$id" >> "$CONFIG/extensions"
    sed -i.bak '/^none$/d' "$CONFIG/extensions" && rm -f "$CONFIG/extensions.bak"
  done
  echo "ok: extensions installed: $* (new workers load them; no restart needed)"
}

cmd_cmux_check() {
  local c
  c=$(cmux_state)
  if [ "$c" = ok ]; then
    echo "ok: cmux socket"
    return 0
  fi
  echo "JARVIS_SETUP: cmux socket not usable ($c). In cmux: Settings > Automation > Socket Control Mode: Automation. Help: $DOC#cmux-socket-mode"
  return 1
}

settings_local() { printf '%s' "$ROOT/.claude/settings.local.json"; }

# Asked once: any recorded answer (on or off) keeps the check quiet.
autoupdate_decided() {
  local f
  f=$(settings_local)
  [ -f "$f" ] && grep -q '"autoUpdate"[[:space:]]*:' "$f"
}

cmd_update_check() {
  [ -f "$CONFIG/update-check" ] && [ "$(tr -d '[:space:]' < "$CONFIG/update-check")" = off ] && return 0
  local branch behind
  branch=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  if GIT_TERMINAL_PROMPT=0 run_bounded 15 git -C "$ROOT" fetch --quiet origin 2>/dev/null; then
    behind=$(git -C "$ROOT" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)
    if [ "${behind:-0}" -gt 0 ]; then
      echo "JARVIS_UPDATE: this home is $behind commit(s) behind $branch. Offer the update; after the user approves run /updatefirstmate (or git -C $ROOT pull --ff-only). Turn this check off: echo off > config/update-check"
    fi
  else
    echo "JARVIS_UPDATE: could not reach origin to check for updates (skipped; offline is fine)"
  fi
  if ! autoupdate_decided; then
    echo "JARVIS_UPDATE: plugin auto-update is not set. Ask once whether Claude Code should update the Jarvis plugins at startup; record the answer with bin/jarvis-setup.sh plugin-autoupdate on|off (update now instead: claude plugin marketplace update $MARKET)"
  fi
}

run_bounded() {  # <seconds> <cmd...>
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@" & local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local killer=$!
    wait "$pid"; local rc=$?
    kill "$killer" 2>/dev/null
    return $rc
  fi
}

cmd_plugin_autoupdate() {
  local want f src
  case "${1:-}" in on) want=true ;; off) want=false ;; *) die "usage: plugin-autoupdate on|off" ;; esac
  f=$(settings_local)
  mkdir -p "$(dirname "$f")"
  src=$(marketplace_source)
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to edit $f"
  python3 - "$f" "$MARKET" "$src" "$want" <<'PY'
import json, os, sys
path, market, src, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true"
data = {}
if os.path.exists(path):
    with open(path) as fh:
        data = json.load(fh)
source = {"source": "github", "repo": src} if not src.startswith("/") else {"source": "directory", "path": src}
entry = data.setdefault("extraKnownMarketplaces", {}).setdefault(market, {"source": source})
entry.setdefault("source", source)
entry["autoUpdate"] = want
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  echo "ok: plugin auto-update $1 ($f)"
}

case "${1:-}" in
  detect) cmd_detect ;;
  status) cmd_status ;;
  backend) shift; cmd_backend "$@" ;;
  plugins) cmd_plugins ;;
  extensions) shift; cmd_extensions "$@" ;;
  cmux-check) cmd_cmux_check ;;
  update-check) cmd_update_check ;;
  plugin-autoupdate) shift; cmd_plugin_autoupdate "$@" ;;
  *) awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 2 ;;
esac
