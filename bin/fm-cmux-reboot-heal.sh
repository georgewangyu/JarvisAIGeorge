#!/usr/bin/env bash
# Heal this home's cmux-backed workers after a machine reboot or a cmux relaunch.
#
# Usage: fm-cmux-reboot-heal.sh [--force] [--dry-run]
#
# Run by bin/fm-session-start.sh on the locked path, beside the stale Herdr
# cleanup; the caller must already own this home's session lock. It is inert
# unless some state/<id>.meta records backend=cmux and the cmux socket answers,
# and FM_CMUX_HEAL=off turns it off. docs/cmux-backend.md "Reboot heal" owns
# the operator view.
#
# Epoch: "<boot epoch> <cmux app pid>", so an app relaunch counts like a reboot.
# The first run on a home only records it in state/.cmux-heal-epoch. A new
# epoch heals once the app has been up FM_CMUX_HEAL_APP_SETTLE seconds (45),
# and while anything is still pending (a tab whose state cannot be read yet, or
# an open ask) a detached retry repeats the pass every FM_CMUX_HEAL_RETRY
# seconds (60) for at most FM_CMUX_HEAL_WINDOW seconds (3600) before the epoch
# is stamped. --force runs a pass outside a new epoch; --dry-run reports what it
# would do and changes nothing (no stamp, no keys, no record writes).
#
# Per ordinary (non-secondmate) task, in order:
#   1. Stale endpoint ids: the tab is found again by its scoped label (title or
#      description, every window) and the meta window=/cmux_*_id= lines are
#      rewritten under the task's meta lock.
#   2. Unstarted or unreadable surface: the tab is selected once so cmux starts
#      its terminal, then the window's previous selection is restored.
#   3. Prompt hooks: each config/cmux-heal-hooks.d/<name>.sh (or the directory
#      in FM_CMUX_HEAL_HOOKS) may define fm_heal_hook_<name>_match <screen>,
#      fm_heal_hook_<name>_answer <workspace> <surface> <screen>, and
#      fm_heal_hook_<name>_ask. A matched prompt is answered only when the hook
#      says it is safe; otherwise its one-line ask is raised. No hooks ship;
#      without one a y/n prompt is a dialog and is left alone with an ask.
#   4. Restore text typed into a live agent's composer (`cmux restore ...`) is
#      erased with Backspace and the composer re-read; never Enter.
#   5. A folder-trust dialog naming the task's own recorded copy is answered yes.
#   6. A bare shell (bin/backends/cmux.sh fm_backend_cmux_agent_state = dead):
#      Ctrl-U and `cmux restore --surface`, then for a claude task with a
#      recorded claude_session_id `bin/fm-spawn.sh <id> --relaunch --resume`.
#      Anything still agent-free is reported once and left to the ordinary
#      dead-endpoint recovery.
#   7. A worker brought back by cmux restore whose instructions run a recurring
#      loop gets one steering message to re-arm it (--resume carries the same
#      note).
# Then, with the Workers layout on, a board whose heartbeat
# (state/.cmux-board-beat, written only by this home's board) is stale and whose
# header holds only an idle shell is started again for this home.
#
# Asks land in state/cmux-heal-status.md and one `cmux notify` per epoch. It
# never types into a tty running anything but a login shell, except the
# Backspace erase and a hook-approved answer; never presses Enter on a composer
# it did not prove empty; never answers "No, exit". Output is one
# `BOOTSTRAP_INFO: cmux reboot heal: <fact>` line per action, ask, or leftover.
# Always exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_ROOT FM_HOME
FORCE=${FM_CMUX_HEAL_FORCE:-0}
DRY=0
for a in "$@"; do
  case "$a" in
    --force|--retry-child) FORCE=1 ;;
    --dry-run) DRY=1 ;;
  esac
done
[ "${FM_CMUX_HEAL:-on}" = off ] && exit 0
SETTLE=${FM_CMUX_HEAL_SETTLE:-20}
APP_SETTLE=${FM_CMUX_HEAL_APP_SETTLE:-45}
RETRY=${FM_CMUX_HEAL_RETRY:-60}
WINDOW=${FM_CMUX_HEAL_WINDOW:-3600}
LOOP_RE=${FM_CMUX_HEAL_LOOP_RE:-'/loop|CronCreate|ScheduleWakeup|hourly|recurring (loop|schedule)'}
HOOKS_DIR=${FM_CMUX_HEAL_HOOKS:-$FM_HOME/config/cmux-heal-hooks.d}
PENDING=0
ASKS=""

info() { printf 'BOOTSTRAP_INFO: cmux reboot heal: %s\n' "$*"; }
ask() { PENDING=1; ASKS="$ASKS- $*"$'\n'; info "ask: $*"; }
# act <description> <command...>: run an action, or only report it in --dry-run.
act() {
  local what=$1; shift
  if [ "$DRY" = 1 ]; then info "would $what"; return 0; fi
  "$@"
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_backend_source cmux >/dev/null 2>&1 || exit 0

metas=()
for m in "$STATE"/*.meta; do
  [ -f "$m" ] || continue
  [ "$(fm_meta_get "$m" backend)" = cmux ] || continue
  [ "$(fm_meta_get "$m" kind)" = secondmate ] && continue
  metas+=("$m")
done
[ "${#metas[@]}" -gt 0 ] || exit 0
[ "$(fm_backend_cmux_ping_state 2>/dev/null)" = ok ] || exit 0

heal_boot_epoch() {
  local raw
  raw=$(sysctl -n kern.boottime 2>/dev/null) && { printf '%s' "$raw" | sed -n 's/.*sec = \([0-9]*\).*/\1/p'; return 0; }
  awk '/^btime/ {print $2}' /proc/stat 2>/dev/null
}
heal_app_pid() {
  fm_backend_cmux_cli top --json 2>/dev/null | jq -r '.memory_diagnostic.app.pid // empty' 2>/dev/null
}
# Seconds the cmux app has been running, from ps etime ([[dd-]hh:]mm:ss).
heal_app_age() {  # <pid>
  local e d=0 h=0 m=0 sec
  e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [ -n "$e" ] || return 1
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  sec=${e##*:}; e=${e%"$sec"}; e=${e%:}
  if [ -n "$e" ]; then m=${e##*:}; e=${e%"$m"}; e=${e%:}; [ -n "$e" ] && h=$e; fi
  printf '%s' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$sec ))
}
APP_PID=$(heal_app_pid)
EPOCH="$(heal_boot_epoch) $APP_PID"
MARK="$STATE/.cmux-heal-epoch"
FIRST="$STATE/.cmux-heal-first"
if [ "$FORCE" != 1 ]; then
  [ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$EPOCH" ] && exit 0
  if [ ! -f "$MARK" ]; then
    # First run on this home: record the epoch only.
    [ "$DRY" = 1 ] || printf '%s\n' "$EPOCH" > "$MARK" 2>/dev/null
    exit 0
  fi
fi

# One pass at a time per home (session start and the detached retry).
LOCK="$STATE/.cmux-heal.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ "$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || date +%s) ))" -gt 900 ] || exit 0
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Let the app finish its own restore before touching anything.
if [ -n "$APP_PID" ] && [ "$DRY" != 1 ]; then
  age=$(heal_app_age "$APP_PID") || age=$APP_SETTLE
  [ "$age" -lt "$APP_SETTLE" ] && sleep $(( APP_SETTLE - age ))
fi
[ -f "$FIRST" ] && [ "$(sed -n 1p "$FIRST" 2>/dev/null)" = "$EPOCH" ] \
  || { [ "$DRY" = 1 ] || printf '%s\n%s\n' "$EPOCH" "$(date +%s)" > "$FIRST"; }

# Prompt hooks (generic seam; none ship).
HOOKS=""
if [ -d "$HOOKS_DIR" ]; then
  for hf in "$HOOKS_DIR"/*.sh; do
    [ -f "$hf" ] || continue
    hn=$(basename "$hf" .sh)
    case "$hn" in *[!a-z0-9_]*) info "hook $hn skipped: name must be [a-z0-9_]"; continue ;; esac
    # shellcheck source=/dev/null
    . "$hf" && HOOKS="$HOOKS $hn"
  done
fi
# heal_hooks <ws> <sf> <screen> <id>: 0 when a hook owned the screen.
heal_hooks() {
  local ws=$1 sf=$2 screen=$3 id=$4 hn
  for hn in $HOOKS; do
    command -v "fm_heal_hook_${hn}_match" >/dev/null 2>&1 || continue
    "fm_heal_hook_${hn}_match" "$screen" || continue
    if [ "$DRY" != 1 ] && command -v "fm_heal_hook_${hn}_answer" >/dev/null 2>&1 \
       && "fm_heal_hook_${hn}_answer" "$ws" "$sf" "$screen"; then
      info "fm-$id: $hn prompt answered by its hook"
    elif [ "$DRY" = 1 ]; then
      info "would let the $hn hook answer fm-$id"
    else
      ask "fm-$id: $( "fm_heal_hook_${hn}_ask" 2>/dev/null || printf '%s prompt waiting' "$hn")"
    fi
    return 0
  done
  return 1
}
# A y/n or similar prompt no hook owns.
heal_is_dialog() {  # <screen>
  printf '%s\n' "$1" | tail -8 | grep -Eq '\[[yY]/[nN]\]|\([yY]/[nN]\)|\[y/N\]|\(y/N\)'
}

ALL=$(fm_backend_cmux_all_workspaces_json) || exit 0
HOMETAG=$(fm_backend_cmux_home_label)

# Locate a task tab by its scoped label in every window: "<ws> <sf> <window>".
heal_locate() {  # <id>
  local want="fm-$HOMETAG-$1" ws sf w
  ws=$(printf '%s' "$ALL" | jq -r --arg l "$want" 'first(.workspaces[]? | select(.title == $l or .description == $l) | .id) // empty' 2>/dev/null)
  [ -n "$ws" ] || return 1
  sf=$(fm_backend_cmux_surface_id_for_workspace "$ws")
  [ -n "$sf" ] || return 1
  w=$(fm_cmux_layout_window_of "$ws")
  printf '%s %s %s' "$ws" "$sf" "$w"
}

# Rewrite the task's endpoint lines under its meta lock (called through act).
# shellcheck disable=SC2329
heal_rewrite_endpoint() {  # <meta> <ws> <sf>
  local meta=$1 ws=$2 sf=$3 lock tmp line
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$STATE/.cmux-heal-meta.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      window=*|cmux_workspace_id=*|cmux_surface_id=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$meta"
  printf 'window=%s:%s\ncmux_workspace_id=%s\ncmux_surface_id=%s\n' "$ws" "$sf" "$ws" "$sf" >> "$tmp"
  chmod "$(stat -f %Lp "$meta" 2>/dev/null || stat -c %a "$meta" 2>/dev/null || echo 644)" "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$meta"
  fm_lock_release "$lock"
}

# Read a tab's screen; select it once when cmux cannot read it yet, then put the
# window's previous selection back.
heal_read() {  # <ws> <sf> <window>
  local ws=$1 sf=$2 w=$3 out prev
  out=$(fm_backend_cmux_cli read-screen --workspace "$ws" --surface "$sf" --lines 40 2>&1) && { printf '%s' "$out"; return 0; }
  case "$out" in *'Failed to read terminal text'*) ;; *) return 1 ;; esac
  [ "$DRY" = 1 ] && { info "would select unreadable tab $ws to start it"; return 1; }
  prev=$(fm_backend_cmux_cli workspace list --window "$w" --json --id-format uuids 2>/dev/null \
    | jq -r '.workspaces[]? | select(.selected == true) | .id' 2>/dev/null | head -1)
  fm_backend_cmux_cli select-workspace --workspace "$ws" --window "$w" >/dev/null 2>&1
  sleep 1
  out=$(fm_backend_cmux_cli read-screen --workspace "$ws" --surface "$sf" --lines 40 2>&1)
  local rc=$?
  [ -n "$prev" ] && [ "$prev" != "$ws" ] && fm_backend_cmux_cli select-workspace --workspace "$prev" --window "$w" >/dev/null 2>&1
  [ "$rc" = 0 ] && printf '%s' "$out"
  return "$rc"
}

# The text after the agent's composer glyph on the last composer row, if it is
# leftover restore input.
heal_restore_residue() {  # <screen>
  local screen=${1//$'\xc2\xa0'/ }
  printf '%s\n' "$screen" | sed -n 's/^[[:space:]]*[❯>][[:space:] ]*\(cmux restore .*\)$/\1/p' | tail -1 | sed 's/[[:space:]]*$//'
}

heal_clear_residue() {  # <ws> <sf> <residue>
  local ws=$1 sf=$2 n i
  n=$(( ${#3} + 8 ))
  i=0
  while [ "$i" -lt "$n" ]; do
    fm_backend_cmux_cli send-key --workspace "$ws" --surface "$sf" backspace >/dev/null 2>&1 || return 1
    i=$((i + 1))
  done
  sleep 0.5
  [ "$(fm_backend_cmux_composer_state "$ws:$sf")" = empty ]
}

heal_trust_wanted() {  # <screen> <worktree>
  local real
  case "$1" in *'Yes, I trust this folder'*) ;; *) return 1 ;; esac
  [ -n "$2" ] || return 1
  real=$(cd "$2" 2>/dev/null && pwd -P) || real=$2
  case "$1" in *"$2"*|*"/private$2"*|*"$real"*) return 0 ;; esac
  return 1
}
heal_trust_dialog() {  # <ws> <sf> <screen> <worktree>
  heal_trust_wanted "$3" "$4" || return 1
  fm_backend_cmux_cli send-key --workspace "$1" --surface "$2" down >/dev/null 2>&1 || return 1
  fm_backend_cmux_cli send-key --workspace "$1" --surface "$2" enter >/dev/null 2>&1
}

heal_wait_alive() {  # <target>
  local i=0
  while [ "$i" -lt "$SETTLE" ]; do
    [ "$(fm_backend_cmux_agent_state "$1")" = alive ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

heal_brief_runs_loop() {  # <id>
  grep -Eqi -- "$LOOP_RE" "$FM_HOME/data/$1/brief.md" 2>/dev/null
}

for meta in "${metas[@]}"; do
  id=$(basename "$meta" .meta)
  loc=$(heal_locate "$id") || { info "fm-$id: tab not found; left for dead-endpoint recovery"; continue; }
  read -r ws sf win <<< "$loc"
  if [ "$(fm_meta_get "$meta" cmux_workspace_id)" != "$ws" ] || [ "$(fm_meta_get "$meta" cmux_surface_id)" != "$sf" ]; then
    if act "refresh fm-$id endpoint ids" heal_rewrite_endpoint "$meta" "$ws" "$sf"; then
      info "fm-$id: endpoint ids refreshed after the relaunch"
    else
      info "fm-$id: could not refresh endpoint ids; skipped"
      continue
    fi
  fi
  target="$ws:$sf"
  wt=$(fm_meta_get "$meta" worktree)
  state=$(fm_backend_cmux_agent_state "$target")
  screen=$(heal_read "$ws" "$sf" "$win") || screen=""
  [ -n "$screen" ] || { PENDING=1; info "fm-$id: screen unreadable even after selecting the tab"; }

  if [ -n "$screen" ] && heal_hooks "$ws" "$sf" "$screen" "$id"; then
    continue
  fi

  if [ "$state" = alive ]; then
    residue=$(heal_restore_residue "$screen")
    if [ -n "$residue" ]; then
      if [ "$DRY" = 1 ]; then
        info "would erase restore text from fm-$id's composer"
      elif heal_clear_residue "$ws" "$sf" "$residue"; then
        info "fm-$id: cleared restore text from a live composer"
      else
        ask "fm-$id: restore text is still in its composer (nothing was submitted); clear it by hand"
      fi
    fi
    if [ "$DRY" = 1 ]; then
      heal_trust_wanted "$screen" "$wt" && info "would answer fm-$id's folder-trust prompt"
    else
      heal_trust_dialog "$ws" "$sf" "$screen" "$wt" && info "fm-$id: answered the folder-trust prompt for its own copy"
    fi
    if heal_is_dialog "$screen"; then ask "fm-$id: a prompt is waiting for an answer"; fi
    continue
  fi

  if [ "$state" != dead ]; then
    if heal_is_dialog "$screen"; then
      ask "fm-$id: a prompt is waiting for an answer"
    elif [ "$state" = unreadable ]; then
      PENDING=1
      info "fm-$id: agent state unreadable; left alone for now"
    fi
    continue
  fi

  if [ "$DRY" = 1 ]; then
    info "would restore fm-$id's bare shell (cmux restore, then session resume)"
    continue
  fi
  fm_backend_cmux_cli send-key --workspace "$ws" --surface "$sf" ctrl+u >/dev/null 2>&1
  fm_backend_cmux_cli send --workspace "$ws" --surface "$sf" "cmux restore --surface" >/dev/null 2>&1
  fm_backend_cmux_cli send-key --workspace "$ws" --surface "$sf" enter >/dev/null 2>&1
  how=""
  if heal_wait_alive "$target"; then
    how="cmux restore"
  elif [ "$(fm_meta_get "$meta" harness)" = claude ] && [ -n "$(fm_meta_get "$meta" claude_session_id)" ] \
       && [ "$(fm_backend_cmux_agent_state "$target")" = dead ]; then
    if "$SCRIPT_DIR/fm-spawn.sh" "$id" --relaunch --resume >/dev/null 2>&1 && heal_wait_alive "$target"; then
      how="session resume"
    fi
  fi
  if [ -z "$how" ]; then
    died="$STATE/.cmux-heal-died-$id"
    if [ "$(cat "$died" 2>/dev/null)" != "$EPOCH" ]; then
      info "fm-$id: no agent after restore or resume; left for dead-endpoint recovery"
      printf '%s\n' "$EPOCH" > "$died" 2>/dev/null
    fi
    continue
  fi
  info "fm-$id: agent back via $how"
  screen=$(heal_read "$ws" "$sf" "$win") || screen=""
  heal_trust_dialog "$ws" "$sf" "$screen" "$wt" && info "fm-$id: answered the folder-trust prompt for its own copy"
  if [ "$how" = "cmux restore" ] && heal_brief_runs_loop "$id" \
     && [ "$(cat "$STATE/.cmux-heal-rearm-$id" 2>/dev/null)" != "$EPOCH" ]; then
    printf '%s\n' "$EPOCH" > "$STATE/.cmux-heal-rearm-$id" 2>/dev/null
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "fm-$id" "Your session was restored after a restart. If your instructions asked you to run a recurring loop or schedule, re-arm it now." >/dev/null 2>&1 \
      && info "fm-$id: asked to re-arm its recurring loop"
  fi
done

# Board: restart a dead board in this home's Workers header.
if fm_cmux_layout_enabled; then
  beat="$STATE/.cmux-board-beat"
  age=999999
  [ -f "$beat" ] && age=$(( $(date +%s) - $(stat -f %m "$beat" 2>/dev/null || stat -c %Y "$beat" 2>/dev/null || echo 0) ))
  if [ "$age" -gt $(( 3 * ${FM_CMUX_BOARD_INTERVAL:-10} + 30 )) ]; then
    gw=$(fm_cmux_layout_ensure 2>/dev/null)
    gid=${gw%%$'\t'*}
    w=${gw#*$'\t'}
    anchor=""
    [ -n "$gw" ] && anchor=$(fm_cmux_layout_groups "$w" | jq -r --arg g "$gid" '.groups[]? | select(.ref == $g) | .anchor_workspace_ref // empty' 2>/dev/null)
    if [ -n "$anchor" ]; then
      anchor_endpoint=$(fm_backend_cmux_workspace_surface_for_identity "$anchor")
      if [ -n "$anchor_endpoint" ]; then
        aid=${anchor_endpoint%%$'\t'*}; asf=${anchor_endpoint#*$'\t'}
      fi
      if [ -n "$anchor_endpoint" ] && [ "$(fm_backend_cmux_agent_state "$aid:$asf")" = dead ] \
         && ! fm_backend_cmux_surface_procs "$aid" "$asf" | cut -f1 | while read -r p; do ps -p "$p" -o args= 2>/dev/null; done | grep -q 'fm-cmux-board.sh'; then
        act "restart the Workers board" fm_cmux_layout_start_board "$anchor" && info "restarted the Workers board"
      fi
    fi
  fi
fi

[ "$DRY" = 1 ] && exit 0

# Asks: one status file, one notification per epoch.
STATUS="$STATE/cmux-heal-status.md"
if [ -n "$ASKS" ]; then
  printf '# cmux reboot heal\n\nEpoch %s, %s\n\n%s' "$EPOCH" "$(date '+%Y-%m-%d %H:%M %Z')" "$ASKS" > "$STATUS" 2>/dev/null
  if [ "$(cat "$STATE/.cmux-heal-notified" 2>/dev/null)" != "$EPOCH" ]; then
    fm_backend_cmux_cli notify --title "Fleet heal" --subtitle "after restart" \
      --body "$(printf '%s' "$ASKS" | head -3 | tr '\n' ' ')" >/dev/null 2>&1
    printf '%s\n' "$EPOCH" > "$STATE/.cmux-heal-notified" 2>/dev/null
  fi
else
  rm -f "$STATUS" 2>/dev/null
fi

started=$(sed -n 2p "$FIRST" 2>/dev/null)
case "$started" in ''|*[!0-9]*) started=$(date +%s) ;; esac
if [ "$PENDING" = 1 ] && [ $(( $(date +%s) - started )) -lt "$WINDOW" ]; then
  # Retry detached so session start never waits on it.
  ( sleep "$RETRY"; FM_HOME="$FM_HOME" FM_CMUX_HEAL_FORCE=1 "$0" --retry-child >> "$STATE/.cmux-heal.log" 2>&1 ) \
    </dev/null >/dev/null 2>&1 &
  exit 0
fi
printf '%s\n' "$EPOCH" > "$MARK" 2>/dev/null || true
exit 0
