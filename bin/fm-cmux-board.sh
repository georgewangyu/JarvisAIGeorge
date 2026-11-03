#!/usr/bin/env bash
# fm-cmux-board.sh - read-only live fleet board for the cmux Workers layout.
#
# Usage: FM_HOME=<home> bin/fm-cmux-board.sh [--once | --passes <n>]
#
# Runs in the generated header workspace of a home's "<Home>: Workers" group
# (bin/backends/cmux-layout.sh starts it). Every FM_CMUX_BOARD_INTERVAL seconds
# (default 10) it reads each task's current state through bin/fm-crew-state.sh
# with forge reads off (every task in the home, each row naming its backend;
# an unverified state stays `unknown` with its reason, never counted as
# working), redraws a small table only when it changed, and asks
# the layout to rename the group with live counts and color each worker tab:
# needs you = Orange, done = Charcoal, working = no color.
#
# It never steers, types into, wakes, or closes a worker; supervision and
# cleanup stay with the watcher and bin/fm-teardown.sh. Each pass touches
# state/.cmux-board-beat so bin/fm-cmux-reboot-heal.sh can tell a dead board.
# --once prints one board and exits; --passes <n> runs n full passes, group
# sync included, then exits (tests and manual checks). FM_CREW_STATE_BIN
# stubs the state read in tests, the same seam bin/fm-classify-lib.sh uses. docs/cmux-backend.md "Workers layout".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_ROOT FM_HOME
STATE="$FM_HOME/state"
INTERVAL="${FM_CMUX_BOARD_INTERVAL:-10}"
ONCE=0
PASSES=0
case "${1:-}" in
  --once) ONCE=1 ;;
  --passes) PASSES=${2:-1}; case "$PASSES" in ''|*[!0-9]*) PASSES=1 ;; esac ;;
esac

# shellcheck source=/dev/null
. "$FM_ROOT/bin/backends/cmux.sh"

meta_get() {  # <file> <key>
  local line v=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) v=${line#"$2="} ;; esac
  done < "$1"
  printf '%s' "$v"
}

render() {  # -> board text on stdout; "<ws>\t<bucket>" lines on fd 3
  local m id ws st line b be dt tt n_work=0 n_need=0 n_done=0 n_unk=0 rows=""
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    id=$(basename "$m" .meta)
    [ "$(meta_get "$m" kind)" = secondmate ] && continue
    ws=$(meta_get "$m" cmux_workspace_id)
    be=$(meta_get "$m" backend)
    [ -n "$be" ] || be=tmux
    line=$(FM_CREW_STATE_NO_FORGE=1 "${FM_CREW_STATE_BIN:-$FM_ROOT/bin/fm-crew-state.sh}" "$id" 2>/dev/null | head -1)
    st=${line#state: }; st=${st%% *}
    [ -n "$st" ] || st=unknown
    b=$(fm_cmux_layout_bucket "$st")
    case "$b" in
      'needs you') n_need=$((n_need + 1)) ;;
      done) n_done=$((n_done + 1)) ;;
      working) n_work=$((n_work + 1)) ;;
      *) n_unk=$((n_unk + 1)) ;;
    esac
    dt=$(meta_get "$m" display_title)
    rows="$rows$(printf '  %-10s %-28s %-7s %s' "$b" "$id" "$be" "$st")"$'\n'
    [ -n "$dt" ] && rows="$rows$(printf '  %-10s %s' '' "$dt")"$'\n'
    if [ "$b" = unknown ]; then
      rows="$rows$(printf '  %-10s %s' '' "$(fm_cmux_layout_unknown_reason "$line")")"$'\n'
    fi
    tt=""
    [ -n "$dt" ] && tt=$(fm_cmux_layout_task_title "$id" "$dt")
    [ "$be" = cmux ] && [ -n "$ws" ] && printf '%s\t%s\t%s\n' "$ws" "$b" "$tt" >&3
  done
  SUMMARY=""
  [ "$n_work" -gt 0 ] && SUMMARY="$n_work working"
  [ "$n_need" -gt 0 ] && SUMMARY="${SUMMARY:+$SUMMARY · }$n_need needs you"
  [ "$n_unk" -gt 0 ] && SUMMARY="${SUMMARY:+$SUMMARY · }$n_unk unknown"
  [ "$n_done" -gt 0 ] && SUMMARY="${SUMMARY:+$SUMMARY · }$n_done done"
  printf '%s\n' "$(fm_cmux_layout_workers_label)"
  printf '  %s\n\n' "${SUMMARY:-idle}"
  if [ -n "$rows" ]; then printf '%s' "$rows"; else printf '  no workers\n'; fi
}

prev=""
while :; do
  tsv=$(mktemp "${TMPDIR:-/tmp}/fm-board.XXXXXX")
  SUMMARY=""
  board=$(render 3>"$tsv")
  SUMMARY=$(printf '%s\n' "$board" | sed -n 2p | sed 's/^  //')
  [ "$SUMMARY" = idle ] && SUMMARY=""
  if [ "$ONCE" = 1 ]; then
    printf '%s\n' "$board"
    rm -f "$tsv"
    exit 0
  fi
  touch "$STATE/.cmux-board-beat" 2>/dev/null
  note=""
  if fm_cmux_layout_enabled; then
    w=$(fm_cmux_layout_window_of "$(cat "$STATE/.cmux-manager-ws" 2>/dev/null)")
    gid=""
    [ -n "$w" ] && gid=$(fm_cmux_layout_find_group "$w")
    if [ -n "$gid" ]; then
      fm_cmux_layout_sync "$w" "$gid" "$SUMMARY" < "$tsv"
      note=$FM_CMUX_LAYOUT_TITLE_ERROR
    elif [ -z "$w" ]; then
      note="cannot find the manager tab's window"
    else
      note="cannot find the Workers group"
    fi
  fi
  [ -z "$note" ] || board="$board"$'\n\n'"  title sync: $note"
  if [ "$board" != "$prev" ]; then
    printf '\033[H\033[2J%s\n' "$board"
    prev=$board
  fi
  rm -f "$tsv"
  if [ "$PASSES" -gt 0 ]; then
    PASSES=$((PASSES - 1))
    [ "$PASSES" -gt 0 ] || exit 0
  fi
  sleep "$INTERVAL"
done
