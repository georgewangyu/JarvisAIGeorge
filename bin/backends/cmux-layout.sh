#!/usr/bin/env bash
# bin/backends/cmux-layout.sh - opt-in Jarvis sidebar layout for the cmux adapter.
#
# Sourced by bin/backends/cmux.sh. Inert unless the home opts in with
# config/cmux-layout containing `workers` (or FM_CMUX_LAYOUT=workers for one
# launch). docs/cmux-backend.md "Workers layout" owns the operator contract.
#
# Layout, per home and per cmux window:
#
#   [pinned] JarvisAIGeorge                 <- the manager tab, standalone
#   [pinned] JarvisAIGeorge: Workers · 2 working · 1 needs you
#              (header runs bin/fm-cmux-board.sh, read-only)
#              ◆ fix-login                  <- one workspace per task
#              ◆ add-tests
#
# A secondmate home uses "Friday <N> · <Charter>" as its home name, so each one gets its
# own manager tab and Workers group in the same sidebar.
#
# Identity: with the layout on, a task workspace's visible title is
# `◆ <task-id>` and its scoped label `fm-<home-tag>-<id>` moves to the cmux
# workspace description. Every lookup in cmux.sh accepts either field, so
# recovery, list, and cleanup keep their home scoping.
#
# Every function here is best effort: a failed group or color call never fails
# a spawn; the task simply lands as an ungrouped workspace.

FM_CMUX_LAYOUT_WORKER_MARK="${FM_CMUX_LAYOUT_WORKER_MARK:-◆}"
FM_CMUX_LAYOUT_PRIMARY_HEX="${FM_CMUX_LAYOUT_PRIMARY_HEX:-#1ABC9C}"
FM_CMUX_LAYOUT_FRIDAY_HEX="${FM_CMUX_LAYOUT_FRIDAY_HEX:-#8E44AD}"
FM_CMUX_LAYOUT_ICON="${FM_CMUX_LAYOUT_ICON:-bolt.fill}"

fm_cmux_layout_enabled() {
  local v="${FM_CMUX_LAYOUT:-}" f="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/cmux-layout"
  if [ -z "$v" ] && [ -f "$f" ]; then
    v=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  fi
  [ "$v" = workers ]
}

# The secondmate id of this home, or empty for a primary.
fm_cmux_layout_secondmate_id() {
  local m="$FM_HOME/${FM_BACKEND_HOMETAG_SECONDMATE_MARKER:-.fm-secondmate-home}"
  [ -f "$m" ] && tr -d '[:space:]' < "$m" 2>/dev/null
  return 0
}

# Visible manager-tab name. config/cmux-home-name wins. Otherwise a primary is
# "JarvisAIGeorge" and a secondmate home is "Friday <N> · <Charter>": N is the
# home's 1-based position in its local parent's data/secondmates.md (omitted
# when the parent cannot be read, e.g. a remote parent), and Charter is
# config/cmux-charter-name or the secondmate id in title case.
fm_cmux_layout_home_name() {
  local f="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/cmux-home-name" n="" sm num charter
  [ -f "$f" ] && IFS= read -r n < "$f"
  if [ -z "$n" ] && [ -z "$(fm_cmux_layout_secondmate_id)" ]; then
    f="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/manager-name"
    [ -f "$f" ] && IFS= read -r n < "$f"
  fi
  if [ -z "$n" ]; then
    sm=$(fm_cmux_layout_secondmate_id)
    if [ -n "$sm" ]; then
      charter=$(fm_cmux_layout_charter_name "$sm")
      num=$(fm_cmux_layout_friday_number "$sm")
      if [ -n "$num" ]; then n="Friday $num · $charter"; else n="Friday · $charter"; fi
    else
      n="JarvisAIGeorge"
    fi
  fi
  printf '%s' "$n"
}

fm_cmux_layout_charter_name() {  # <secondmate-id>
  local f="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/cmux-charter-name" c=""
  [ -f "$f" ] && IFS= read -r c < "$f"
  if [ -z "$c" ]; then
    c=$(printf '%s' "$1" | tr '_-' '  ' | awk '{for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print}')
  fi
  printf '%s' "$c"
}

# The secondmate's 1-based position among its parent's registry rows, or empty.
fm_cmux_layout_friday_number() {  # <secondmate-id>
  local id=$1 binding="$FM_HOME/.fm-secondmate-parent" parent="" line n=0 key
  [ -f "$binding" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in parent_home=*) parent=${line#parent_home=} ;; esac
  done < "$binding"
  [ -n "$parent" ] && [ -f "$parent/data/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*' - '*) ;; *) continue ;; esac
    n=$((n + 1))
    key=${line#- }
    key=${key%% *}
    [ "$key" = "$id" ] && { printf '%s' "$n"; return 0; }
  done < "$parent/data/secondmates.md"
  return 0
}

fm_cmux_layout_workers_label() {
  printf '%s: Workers' "$(fm_cmux_layout_home_name)"
}

fm_cmux_layout_hex() {
  if [ -n "$(fm_cmux_layout_secondmate_id)" ]; then
    printf '%s' "$FM_CMUX_LAYOUT_FRIDAY_HEX"
  else
    printf '%s' "$FM_CMUX_LAYOUT_PRIMARY_HEX"
  fi
}

fm_cmux_layout_task_title() {  # <fm-task-label>
  local id=${1#fm-}
  printf '%s %s' "$FM_CMUX_LAYOUT_WORKER_MARK" "$id"
}

# The manager workspace: the caller's own cmux workspace, recorded once per
# home in state/.cmux-manager-ws so a spawn run from another shell still finds
# it. A recorded id that no longer exists is replaced by the caller.
fm_cmux_layout_manager_ws() {
  local rec="$FM_HOME/state/.cmux-manager-ws" ws="" caller
  [ -f "$rec" ] && IFS= read -r ws < "$rec"
  if [ -n "$ws" ] && [ -n "$(fm_cmux_layout_window_of "$ws")" ]; then
    printf '%s' "$ws"; return 0
  fi
  caller=${CMUX_WORKSPACE_ID:-}
  [ -n "$caller" ] || caller=$(fm_backend_cmux_cli identify --json --id-format uuids 2>/dev/null | jq -r '.caller.workspace_id // empty' 2>/dev/null)
  [ -n "$caller" ] || return 1
  mkdir -p "$FM_HOME/state" 2>/dev/null && printf '%s\n' "$caller" > "$rec" 2>/dev/null
  printf '%s' "$caller"
}

fm_cmux_layout_window_of() {  # <workspace-id>
  local info
  info=$(fm_backend_cmux_window_of_workspace "$1")
  printf '%s' "${info%% *}"
}

fm_cmux_layout_groups() {  # <window>
  fm_backend_cmux_cli workspace-group list --window "$1" --json 2>/dev/null
}

fm_cmux_layout_find_group() {  # <window> -> group ref
  local w=$1 label
  label=$(fm_cmux_layout_workers_label)
  fm_cmux_layout_groups "$w" | jq -r --arg l "$label" \
    '.groups[]? | select(.name == $l or ((.name // "") | startswith($l + " "))) | .ref' 2>/dev/null | head -1
}

# Mutual exclusion for group creation: two spawns racing here would each make a
# Workers group. A mkdir lock in this home's state dir, reclaimed after 30s.
fm_cmux_layout_lock() {
  local lk="$FM_HOME/state/.cmux-layout.lock" i=0 age
  mkdir -p "$FM_HOME/state" 2>/dev/null
  while [ "$i" -lt 40 ]; do
    mkdir "$lk" 2>/dev/null && return 0
    age=$(( $(date +%s) - $(stat -f %m "$lk" 2>/dev/null || stat -c %Y "$lk" 2>/dev/null || date +%s) ))
    [ "$age" -gt 30 ] && rmdir "$lk" 2>/dev/null
    i=$((i + 1)); sleep 0.25
  done
  return 1
}
fm_cmux_layout_unlock() { rmdir "$FM_HOME/state/.cmux-layout.lock" 2>/dev/null || true; }

# Start the read-only board in a group's generated header workspace.
fm_cmux_layout_start_board() {  # <anchor-ref>
  local ref=$1 endpoint ws sf i=0 board="$FM_BACKEND_CMUX_ROOT/bin/fm-cmux-board.sh"
  [ -f "$board" ] || return 0
  while [ "$i" -lt 20 ]; do
    endpoint=$(fm_backend_cmux_workspace_surface_for_identity "$ref"); [ -n "$endpoint" ] && break
    i=$((i + 1)); sleep 0.25
  done
  [ -n "$endpoint" ] || return 0
  ws=${endpoint%%$'\t'*}; sf=${endpoint#*$'\t'}
  fm_backend_cmux_cli send --workspace "$ws" --surface "$sf" \
    "FM_HOME=$(printf %q "$FM_HOME") bash $(printf %q "$board")" >/dev/null 2>&1 || return 0
  fm_backend_cmux_cli send-key --workspace "$ws" --surface "$sf" Enter >/dev/null 2>&1 || true
}

# Name, pin, and color the manager tab, and keep it right before its Workers
# group header. Never moves a group header (cmux ignores that); moves the tab.
fm_cmux_layout_place_manager() {  # <manager-ws> <window> [<group-ref>]
  local ws=$1 w=$2 gid=${3:-} anchor
  fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action rename --title "$(fm_cmux_layout_home_name)" >/dev/null 2>&1
  fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action pin >/dev/null 2>&1
  fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action set-color --color "$(fm_cmux_layout_hex)" >/dev/null 2>&1
  [ -z "$(fm_cmux_layout_secondmate_id)" ] && \
    fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action move-top >/dev/null 2>&1
  [ -n "$gid" ] || return 0
  anchor=$(fm_cmux_layout_groups "$w" | jq -r --arg g "$gid" '.groups[]? | select(.ref == $g) | .anchor_workspace_ref // empty' 2>/dev/null)
  [ -n "$anchor" ] && fm_backend_cmux_cli reorder-workspace --workspace "$ws" --before "$anchor" --window "$w" >/dev/null 2>&1
  return 0
}

# Session start (any harness): name, pin and color the manager tab without
# creating the Workers group, which the first spawn creates. Best effort.
fm_cmux_layout_claim_manager() {
  local ws w gid
  fm_cmux_layout_enabled || return 0
  ws=$(fm_cmux_layout_manager_ws 2>/dev/null) || return 0
  w=$(fm_cmux_layout_window_of "$ws" 2>/dev/null)
  [ -n "$w" ] || return 0
  gid=$(fm_cmux_layout_find_group "$w" 2>/dev/null)
  fm_cmux_layout_place_manager "$ws" "$w" "$gid" >/dev/null 2>&1
  return 0
}

# Resolve (creating when needed) this home's Workers group in the manager's
# window. Prints "<group-ref>\t<window-id>" or nothing.
fm_cmux_layout_ensure() {
  local mws w gid out anchor locked=0
  mws=$(fm_cmux_layout_manager_ws) || return 0
  w=$(fm_cmux_layout_window_of "$mws")
  [ -n "$w" ] || return 0
  fm_backend_cmux_cli workspace-group list --json >/dev/null 2>&1 || return 0
  gid=$(fm_cmux_layout_find_group "$w")
  if [ -z "$gid" ]; then
    fm_cmux_layout_lock && locked=1
    gid=$(fm_cmux_layout_find_group "$w")
    if [ -z "$gid" ]; then
      out=$(fm_backend_cmux_cli workspace-group create --window "$w" --name "$(fm_cmux_layout_workers_label)" --cwd "$FM_HOME" \
            --idempotency-key "fm-workers-$(fm_backend_cmux_home_label)-$w-$(date +%Y%m%d%H%M)" --json 2>/dev/null)
      gid=$(printf '%s' "$out" | jq -r '.group.ref // empty' 2>/dev/null)
      anchor=$(printf '%s' "$out" | jq -r '.group.anchor_workspace_ref // empty' 2>/dev/null)
      if [ -n "$gid" ]; then
        fm_backend_cmux_cli workspace-group set-color "$gid" --window "$w" --hex "$(fm_cmux_layout_hex)" >/dev/null 2>&1
        fm_backend_cmux_cli workspace-group set-icon "$gid" --window "$w" --symbol "$FM_CMUX_LAYOUT_ICON" >/dev/null 2>&1
        fm_backend_cmux_cli workspace-group pin "$gid" --window "$w" >/dev/null 2>&1
        [ -n "$anchor" ] && fm_cmux_layout_start_board "$anchor"
      fi
    fi
    [ "$locked" = 1 ] && fm_cmux_layout_unlock
  fi
  [ -n "$gid" ] || return 0
  fm_cmux_layout_place_manager "$mws" "$w" "$gid"
  printf '%s\t%s' "$gid" "$w"
}

# Create a task workspace inside the Workers group with exactly one create
# call. Returns 0 when cmux acknowledged it (the caller waits for visibility),
# 1 when the create was attempted but not acknowledged, and 2 when no Workers group is
# available (the caller may use a plain create).
fm_cmux_layout_create() {  # <scoped-label> <cwd>
  local label=$1 cwd=$2 gw gid w
  gw=$(fm_cmux_layout_ensure)
  gid=${gw%%$'\t'*}; w=${gw#*$'\t'}
  [ -n "$gw" ] && [ -n "$gid" ] && [ -n "$w" ] || return 2
  fm_backend_cmux_cli new-workspace --window "$w" --group "$gid" --group-placement end \
        --name "$(fm_cmux_layout_task_title "${label#fm-"$(fm_backend_cmux_home_label)"-}")" \
        --description "$label" --cwd "$cwd" --focus false --id-format uuids >/dev/null 2>&1 || return 1
  return 0
}

# State buckets for the board and tab colors, from fm-crew-state's states.
# Anything that is not a verified state stays `unknown`: it is never counted as
# working, and its tab color is cleared rather than styled.
fm_cmux_layout_bucket() {  # <state>
  case "$1" in
    working|parked) printf 'working' ;;
    done) printf 'done' ;;
    blocked|failed|paused|needs-decision|stale) printf 'needs you' ;;
    *) printf 'unknown' ;;
  esac
}

# One UI pass: rename the group with live counts and color each worker tab.
# The title is re-read after a rename; a title that did not change, or could
# not be read, is left in FM_CMUX_LAYOUT_TITLE_ERROR for the board to show,
# and the next pass tries again. It never touches worker endpoints.
# Input on stdin: "<workspace-id>\t<bucket>" lines. Best effort, only on change.
# shellcheck disable=SC2034 # FM_CMUX_LAYOUT_TITLE_ERROR is read by bin/fm-cmux-board.sh
fm_cmux_layout_sync() {  # <window> <group-ref> <summary>
  local w=$1 gid=$2 summary=$3 ws b color cache="$FM_HOME/state/.cmux-layout-ui" want cur
  cur=$(fm_cmux_layout_groups "$w" | jq -r --arg g "$gid" '.groups[]? | select(.ref == $g) | .name // empty' 2>/dev/null)
  want=$(fm_cmux_layout_workers_label)
  [ -n "$summary" ] && want="$want · $summary"
  FM_CMUX_LAYOUT_TITLE_ERROR=""
  if [ -z "$cur" ]; then
    FM_CMUX_LAYOUT_TITLE_ERROR="could not read the Workers group title"
  elif [ "$cur" != "$want" ]; then
    fm_backend_cmux_cli workspace-group rename "$gid" --window "$w" --name "$want" >/dev/null 2>&1
    cur=$(fm_cmux_layout_groups "$w" | jq -r --arg g "$gid" '.groups[]? | select(.ref == $g) | .name // empty' 2>/dev/null)
    [ "$cur" = "$want" ] || FM_CMUX_LAYOUT_TITLE_ERROR="group title still reads '${cur:-?}'; retrying next pass"
  fi
  touch "$cache" 2>/dev/null
  while IFS=$'\t' read -r ws b; do
    [ -n "$ws" ] || continue
    grep -qxF "$ws	$b" "$cache" 2>/dev/null && continue
    case "$b" in
      'needs you') color=Orange ;;
      done) color=Charcoal ;;
      *) color="" ;;
    esac
    if [ -n "$color" ]; then
      fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action set-color --color "$color" >/dev/null 2>&1
    else
      fm_backend_cmux_cli workspace-action --workspace "$ws" --window "$w" --action clear-color >/dev/null 2>&1
    fi
    { grep -v "^$ws	" "$cache" 2>/dev/null; printf '%s\t%s\n' "$ws" "$b"; } > "$cache.tmp" && mv "$cache.tmp" "$cache"
  done
  return 0
}

# The reason shown under an `unknown` board row. A known unverified-source
# token from bin/fm-busy-lib.sh gets a plain explanation of the missing
# capability; anything else shows the detail fm-crew-state gave
# ("state: unknown · source: <s> · <detail>"). It explains, never guesses: the
# row stays unknown either way.
fm_cmux_layout_unknown_reason() {  # <crew-state line>
  local d=${1#*· source: }
  case "$d" in *' · '*) d=${d#* · } ;; *) d="" ;; esac
  case "$d" in
    *codex-unverified*)
      d="Codex gives no verified live state for a terminal worker (its app-server cannot see the pane, and project hooks do not fire); only a finished turn is signalled, so read the tab for progress" ;;
    *kimi-unverified*)
      d="Kimi has no verified live-state source yet; read the tab for progress" ;;
    *capture-failed*)
      d="the worker's tab could not be read" ;;
    *no-target*)
      d="the task record names no tab" ;;
    '') d="no state reading" ;;
  esac
  printf 'why: %s' "$d"
}
