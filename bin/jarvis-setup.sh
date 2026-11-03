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
#   bin/jarvis-setup.sh harness         print the tool this session runs in:
#                                       claude or codex (JARVIS_HARNESS overrides)
#   bin/jarvis-setup.sh backend cmux|tmux|auto
#                                       record the session backend choice:
#                                       cmux writes config/backend=cmux and
#                                       config/cmux-layout=workers (manager tab,
#                                       Workers group, board); tmux writes
#                                       config/backend=tmux; auto leaves the
#                                       backend to runtime detection
#   bin/jarvis-setup.sh plugins         add this repo's plugin marketplace and
#                                       install the core plugin with the current
#                                       tool's CLI (claude plugin install, or
#                                       codex plugin add). Claude: fallback when
#                                       folder trust did not load it. Run only
#                                       after the user approves
#   bin/jarvis-setup.sh extensions <id>...|none
#                                       install the extensions the user approved
#                                       (recommended: george-coding-agent) and
#                                       record the choice in config/extensions
#   bin/jarvis-setup.sh cmux-check      verify the cmux control socket answers
#   bin/jarvis-setup.sh update-check    bounded network check: is the home behind
#                                       origin, is plugin auto-update on. Quiet
#                                       when current. Off: config/update-check=off
#   bin/jarvis-setup.sh shortcut add [--name N] [--folder DIR] [--rc FILE]...
#                                       write a marked, idempotent alias block
#                                       (default name jarvis) to ~/.zshrc and
#                                       ~/.bashrc: alias N='cd DIR && <home>/bin/jarvis-launch'.
#                                       Run only after the user approves; prints
#                                       the undo command
#   bin/jarvis-setup.sh shortcut remove [--name N] [--rc FILE]...
#   bin/jarvis-setup.sh shortcut none   record "no shortcut" so setup stops asking
#   bin/jarvis-setup.sh address <name>|none
#                                       how Jarvis addresses the user, in the
#                                       gitignored config/user-address (none: no
#                                       special address, just "you")
#   bin/jarvis-setup.sh plugin-autoupdate on|off
#                                       let Claude Code update the marketplace and
#                                       its plugins at startup (written to the
#                                       home's .claude/settings.local.json;
#                                       Claude only, Codex has no such setting)
#
# Harness: Claude Code and Codex are supported. The harness is JARVIS_HARNESS
# when set to claude or codex, else bin/fm-harness.sh's process-tree answer,
# else whichever CLI is on PATH (claude first). Plugin state is read from that
# tool's own home: CLAUDE_CONFIG_DIR (default ~/.claude) or CODEX_HOME (default
# ~/.codex). A plugin counts as installed from either marketplace,
# jarvis-ai-george or the extension's own (george-coding-agent).
#
# Nothing here installs software on its own: detect, status and update-check
# only read; every other verb is run by the manager after the user approves.
# Lines that need action start with JARVIS_FIRST_RUN:, JARVIS_SETUP: or
# JARVIS_UPDATE: and name docs/install.md for help.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}
HOME_DIR="${FM_HOME:-$ROOT}"
CONFIG="$HOME_DIR/config"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
MARKET=jarvis-ai-george
# Marketplaces a plugin may have been installed from: ours, or the extension's own repo.
MARKETS="jarvis-ai-george george-coding-agent"
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

harness() {  # prints claude|codex
  case "${JARVIS_HARNESS:-}" in claude|codex) printf '%s' "$JARVIS_HARNESS"; return ;; esac
  local h
  h=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  case "$h" in claude|codex) printf '%s' "$h"; return ;; esac
  if command -v claude >/dev/null 2>&1; then printf claude
  elif command -v codex >/dev/null 2>&1; then printf codex
  else printf claude
  fi
}
HARNESS=$(harness)

# Claude: folder trust loads an enabled same-repo plugin into the cache without
# an installed_plugins.json entry, so either counts. Codex: `codex plugin add`
# installs into plugins/cache/<marketplace>/<plugin>/.
plugin_installed() {  # <plugin>
  local m f="$CLAUDE_DIR/plugins/installed_plugins.json"
  for m in $MARKETS; do
    if [ "$HARNESS" = codex ]; then
      [ -d "$CODEX_DIR/plugins/cache/$m/$1" ] && return 0
    else
      { [ -f "$f" ] && grep -q "\"$1@$m\"" "$f"; } && return 0
      [ -d "$CLAUDE_DIR/plugins/cache/$m/$1" ] && return 0
    fi
  done
  return 1
}

# The plugin CLI of the current harness; only these verbs differ.
need_cli() { command -v "$HARNESS" >/dev/null 2>&1 || die "$HARNESS is not on PATH"; }

ensure_marketplace() {
  "$HARNESS" plugin marketplace list 2>/dev/null | grep -q "$MARKET" && return 0
  "$HARNESS" plugin marketplace add "$(marketplace_source)" \
    || die "marketplace add $(marketplace_source) failed (help: $DOC#plugins-did-not-install)"
}

install_plugin() {  # <plugin>
  if [ "$HARNESS" = codex ]; then
    codex plugin add "$1@$MARKET"
  else
    claude plugin install "$1@$MARKET" --scope user
  fi
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
  [ -f "$CONFIG/user-address" ] || gaps+=("how to address the user not asked")
  [ -f "$CONFIG/shortcut" ] || gaps+=("launch shortcut not offered")
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

# Three separate facts, from FirstMate's own resolver (bin/fm-backend.sh) so the
# precedence is never re-derived here: the saved choice, the terminal this
# session is in, and where a new worker spawns by default (FM_BACKEND, else
# config/backend, else the detected terminal, else tmux). A task's explicit
# --backend can still differ. Read-only: nothing here changes the saved choice.
backend_explain() {
  local saved detected effective
  saved=none
  [ -f "$CONFIG/backend" ] && saved=$(tr -d '[:space:]' < "$CONFIG/backend")
  # shellcheck disable=SC1091  # sourced from this script's own directory
  detected=$( (FM_HOME="$HOME_DIR" . "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 \
    && fm_backend_detect >/dev/null 2>&1 && printf '%s' "$FM_BACKEND_DETECTED") 2>/dev/null )
  # shellcheck disable=SC1091  # sourced from this script's own directory
  effective=$( (FM_HOME="$HOME_DIR" . "$SCRIPT_DIR/fm-backend.sh" >/dev/null 2>&1 \
    && fm_backend_name 2>/dev/null) 2>/dev/null )
  echo "ok: backend saved choice: ${saved:-none}$([ "$saved" = none ] && printf ' (auto)' || printf ' (config/backend)')"
  echo "ok: terminal detected: ${detected:-none (not inside tmux, herdr or cmux)}"
  local why
  if [ -n "${FM_BACKEND:-}" ]; then
    why="FM_BACKEND is set for this session"
  elif [ "$saved" != none ]; then
    why="the saved choice wins"
    [ -n "$detected" ] && [ "$detected" != "$saved" ] && why="the saved choice wins over the $detected terminal you are in"
  elif [ -n "$detected" ]; then
    why="no saved choice, so the detected terminal"
  else
    why="no saved choice and no detected terminal, so the default"
  fi
  echo "ok: new workers spawn in: ${effective:-unknown} ($why; a task's own --backend can differ)"
}

cmd_status() {
  local b p t c
  echo "ok: harness $HARNESS"
  b=$(backend_choice)
  if [ "$b" = unset ]; then
    echo "JARVIS_SETUP: MISSING backend choice (ask the user: use cmux tabs? then bin/jarvis-setup.sh backend cmux|tmux|auto)"
  else
    echo "ok: backend $b"
    backend_explain
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
  if [ -f "$CONFIG/user-address" ]; then
    echo "ok: address $(cat "$CONFIG/user-address")"
  else
    echo "JARVIS_SETUP: MISSING address. Ask \"What should Jarvis call you?\" (default: no special address); record it with bin/jarvis-setup.sh address <name>|none"
  fi
  if [ -f "$CONFIG/shortcut" ]; then
    echo "ok: shortcut $(cat "$CONFIG/shortcut")"
  else
    echo "JARVIS_SETUP: MISSING shortcut choice. Ask whether to add a launch shortcut (name, default jarvis) and which folder it starts in (default: the folder setup runs from, else your home folder); after a yes run bin/jarvis-setup.sh shortcut add --name <n> --folder <dir>, or shortcut none (help: $DOC#launch-shortcut)"
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
  need_cli
  local p
  ensure_marketplace
  for p in $PLUGINS; do
    plugin_installed "$p" || install_plugin "$p" \
      || die "plugin install $p failed (help: $DOC#plugins-did-not-install)"
  done
  echo "ok: plugins $PLUGINS (restart $HARNESS in this folder to load them)"
}

cmd_extensions() {
  [ "$#" -gt 0 ] || die "usage: extensions <id>...|none"
  mkdir -p "$CONFIG"
  if [ "$1" = none ]; then
    echo none > "$CONFIG/extensions"
    echo "ok: no extensions (install one later with bin/jarvis-setup.sh extensions <id>)"
    return 0
  fi
  need_cli
  local id
  for id in "$@"; do
    case " $EXTENSIONS " in *" $id "*) ;; *) die "unknown extension '$id' (known: $EXTENSIONS)" ;; esac
    ensure_marketplace
    plugin_installed "$id" || install_plugin "$id" \
      || die "plugin install $id failed (help: $DOC#plugins-did-not-install)"
    grep -qx "$id" "$CONFIG/extensions" 2>/dev/null || echo "$id" >> "$CONFIG/extensions"
    sed -i.bak '/^none$/d' "$CONFIG/extensions" && rm -f "$CONFIG/extensions.bak"
  done
  if [ "$HARNESS" = codex ]; then
    echo "ok: extensions installed: $* (new workers load them; restart codex here to use their skills in this session)"
  else
    echo "ok: extensions installed: $* (new workers load them; no restart needed)"
  fi
}

cmd_address() {
  [ "$#" -ge 1 ] || die "usage: address <name>|none"
  mkdir -p "$CONFIG"
  local v="$*"
  case "$v" in *$'\n'*) die "address must be one line" ;; esac
  printf '%s\n' "$v" > "$CONFIG/user-address"
  if [ "$v" = none ]; then echo "ok: no special address (Jarvis says \"you\")"; else echo "ok: Jarvis will call you $v"; fi
}

shortcut_rcs() {  # prints the rc files to edit, one per line (given or the defaults)
  if [ "${#SHORTCUT_RCS[@]}" -gt 0 ]; then
    printf '%s\n' "${SHORTCUT_RCS[@]}"
    return
  fi
  local found=0 f
  for f in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; found=1; }
  done
  if [ "$found" = 0 ]; then
    case "$(basename "${SHELL:-zsh}")" in bash) printf '%s\n' "$HOME/.bashrc" ;; *) printf '%s\n' "$HOME/.zshrc" ;; esac
  fi
}

shortcut_strip() {  # <rc> <name>: remove that shortcut's marked block, if any
  local rc=$1 name=$2 tmp
  [ -f "$rc" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jarvis-rc.XXXXXX") || die "mktemp failed"
  awk -v b="# >>> jarvis-launch shortcut: $name " -v e="# <<< jarvis-launch shortcut: $name <<<" '
    index($0, b) == 1 { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }' "$rc" > "$tmp" && cat "$tmp" > "$rc"
  rm -f "$tmp"
}

cmd_shortcut() {
  local sub=${1:-} name=jarvis folder='' rc
  [ -n "$sub" ] && shift
  SHORTCUT_RCS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name=${2:-}; shift 2 ;;
      --folder) folder=${2:-}; shift 2 ;;
      --rc) SHORTCUT_RCS+=("${2:-}"); shift 2 ;;
      *) die "unknown shortcut option '$1'" ;;
    esac
  done
  printf '%s' "$name" | grep -Eq '^[A-Za-z_][A-Za-z0-9_-]*$' || die "shortcut name must be a plain word: '$name'"
  mkdir -p "$CONFIG"
  case "$sub" in
    add)
      [ -n "$folder" ] || folder=$PWD
      folder=$(cd "$folder" 2>/dev/null && pwd) || die "folder does not exist"
      case "$folder$ROOT" in *"'"*) die "paths with a single quote are not supported" ;; esac
      while read -r rc; do
        shortcut_strip "$rc" "$name"
        {
          printf '# >>> jarvis-launch shortcut: %s (added by bin/jarvis-setup.sh; undo: %s/bin/jarvis-setup.sh shortcut remove --name %s) >>>\n' "$name" "$ROOT" "$name"
          printf "alias %s='cd %s && %s/bin/jarvis-launch'\n" "$name" "$folder" "$ROOT"
          printf '# <<< jarvis-launch shortcut: %s <<<\n' "$name"
        } >> "$rc"
        echo "ok: shortcut $name in $rc"
      done < <(shortcut_rcs)
      printf '%s %s\n' "$name" "$folder" > "$CONFIG/shortcut"
      echo "Open a new terminal (or source the file), then type: $name"
      echo "Undo: $ROOT/bin/jarvis-setup.sh shortcut remove --name $name"
      ;;
    remove)
      while read -r rc; do
        shortcut_strip "$rc" "$name" && echo "ok: removed shortcut $name from $rc"
      done < <(shortcut_rcs)
      rm -f "$CONFIG/shortcut"
      ;;
    none)
      echo none > "$CONFIG/shortcut"
      echo "ok: no shortcut (add one later with bin/jarvis-setup.sh shortcut add)"
      ;;
    *) die "usage: shortcut add|remove|none [--name N] [--folder DIR] [--rc FILE]" ;;
  esac
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
  if [ "$HARNESS" = claude ] && ! autoupdate_decided; then
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
  harness) echo "$HARNESS" ;;
  backend) shift; cmd_backend "$@" ;;
  plugins) cmd_plugins ;;
  extensions) shift; cmd_extensions "$@" ;;
  cmux-check) cmd_cmux_check ;;
  update-check) cmd_update_check ;;
  plugin-autoupdate) shift; cmd_plugin_autoupdate "$@" ;;
  shortcut) shift; cmd_shortcut "$@" ;;
  address) shift; cmd_address "$@" ;;
  *) awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 2 ;;
esac
