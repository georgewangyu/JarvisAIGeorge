#!/usr/bin/env bash
# tests/fm-cmux-reboot-heal.test.sh - fake-cmux tests for the cmux
# recovery-grade agent-state probe (bin/backends/cmux.sh
# fm_backend_cmux_agent_state) and the reboot heal pass
# (bin/fm-cmux-reboot-heal.sh). A stateful fake `cmux` and a fake `ps` on PATH
# model one window, task tabs, their tty foreground process groups, and their
# screens; no real cmux is touched. Live evidence: docs/cmux-backend.md
# "Reboot heal".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-cmux-reboot-heal-tests)

WIN=FAKEWIN

# make_fake <dir>: fake `cmux` and `ps`. State lives in <dir>/fake:
#   workspaces.json   `workspace list` body for the one window
#   sf.<ws>           the surface id of a workspace
#   tty.<sf> fg.<sf>  the surface's tty and foreground pgid
#   ps.<tty>          `ps -t` rows "<pid> <pgid> <comm>"
#   args.<pid>        `ps -p <pid> -o args=` output
#   screen.<sf>       read-screen text; screen-after-bs.<sf> replaces it once a
#                     backspace was sent, screen-after-enter.<sf> once Enter was
#   restore-works.<sf> when present, Enter after `cmux restore --surface`
#                     turns the surface's foreground into claude
#   unreadable.<sf>   read-screen fails until the workspace is selected
make_fake() {
  local d=$1 fb="$1/bin"
  mkdir -p "$fb" "$d/fake"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
F="$FAKE_DIR"
printf '%s\n' "$*" >> "$F/log"
sub=$1; shift
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$sub" in
  ping) echo PONG ;;
  version) echo "cmux 0.64.25 (106) [fake]" ;;
  rpc)
    [ "${1:-}" = system.tree ] || exit 1
    all='[]'
    while IFS= read -r ws; do
      [ -n "$ws" ] || continue
      sf=$(cat "$F/sf.$ws" 2>/dev/null || printf 'absent-%s' "$ws")
      one=$(jq -c --arg id "$ws" '.workspaces[] | select(.id == $id)' "$F/workspaces.json")
      all=$(printf '%s' "$all" | jq -c --argjson one "$one" --arg sf "$sf" '
        . + [($one + {panes:[{id:("pane-"+$one.id),surface_count:1,
          surface_ids:[$sf],surfaces:[{id:$sf}]}]})]')
    done < <(jq -r '.workspaces[].id' "$F/workspaces.json")
    jq -n --arg win "$FAKE_WIN" --argjson ws "$all" \
      '{windows:[{id:$win,workspace_count:($ws|length),workspaces:$ws}]}' ;;
  list-windows) printf '[{"id":"%s"}]\n' "$FAKE_WIN" ;;
  workspace)
    [ "$1" = list ] && cat "$F/workspaces.json" ;;
  workspace-group)
    [ "$1" = list ] && printf '{"groups":[{"ref":"workspace_group:1","name":"JarvisAIGeorge: Workers","anchor_workspace_ref":"workspace:2"}]}' ;;
  list-panes)
    ws=$(arg --workspace "$@")
    [ -f "$F/sf.$ws" ] || { echo "Error: not_found"; exit 1; }
    sf=$(cat "$F/sf.$ws")
    printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}\n' "$sf" "$sf" ;;
  top)
    ws=$(arg --workspace "$@")
    if [ -n "$ws" ] && [ -f "$F/sf.$ws" ]; then
      sf=$(cat "$F/sf.$ws")
      printf '{"memory_diagnostic":{"app":{"pid":4242}},"windows":[{"workspaces":[{"surfaces":[{"kind":"surface","id":"%s","tty":"%s","foreground_pgids":[%s]}]}]}]}\n' \
        "$sf" "$(cat "$F/tty.$sf")" "$(cat "$F/fg.$sf")"
    else
      echo '{"memory_diagnostic":{"app":{"pid":4242}}}'
    fi ;;
  read-screen)
    sf=$(arg --surface "$@")
    if [ -f "$F/unreadable.$sf" ]; then echo "Error: internal_error: Failed to read terminal text"; exit 1; fi
    if [ -f "$F/screen-after-bs.$sf" ] && grep -q "surface $sf backspace" "$F/log"; then txt=$(cat "$F/screen-after-bs.$sf")
    elif [ -f "$F/screen-after-enter.$sf" ] && grep -q "surface $sf enter" "$F/log"; then txt=$(cat "$F/screen-after-enter.$sf")
    else txt=$(cat "$F/screen.$sf" 2>/dev/null); fi
    case " $* " in *' --json '*) printf '%s' "$txt" | jq -Rs '{text: .}' ;; *) printf '%s\n' "$txt" ;; esac ;;
  select-workspace)
    ws=$(arg --workspace "$@"); [ -f "$F/sf.$ws" ] && rm -f "$F/unreadable.$(cat "$F/sf.$ws")" ;;
  send-key)
    sf=$(arg --surface "$@"); key=${!#}
    if [ "$key" = enter ] && [ -f "$F/restore-works.$sf" ] && grep -q "surface $sf cmux restore --surface" "$F/log"; then
      t=$(cat "$F/tty.$sf"); echo "900 900 claude" > "$F/ps.$t"; echo 900 > "$F/fg.$sf"; echo claude > "$F/args.900"
    fi ;;
  *) : ;;
esac
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
F="$FAKE_DIR"
case "$1" in
  -t) cat "$F/ps.$2" 2>/dev/null ;;
  -p) cat "$F/args.$2" 2>/dev/null ;;
esac
SH
  chmod +x "$fb/cmux" "$fb/ps"
  : > "$d/fake/log"
}

# add_tab <dir> <ws> <sf> <label-desc> <tty> <pid> <comm>
add_tab() {
  local f="$1/fake" ws=$2 sf=$3 desc=$4 tty=$5 pid=$6 comm=$7 cur
  echo "$sf" > "$f/sf.$ws"
  echo "$tty" > "$f/tty.$sf"
  echo "$pid" > "$f/fg.$sf"
  echo "$pid $pid $comm" > "$f/ps.$tty"
  echo "$comm" > "$f/args.$pid"
  cur=$(cat "$f/workspaces.json" 2>/dev/null || echo '{"workspaces":[]}')
  printf '%s' "$cur" | jq --arg id "$ws" --arg d "$desc" '.workspaces += [{id: $id, title: ("◆ x"), description: $d, selected: false}]' > "$f/workspaces.json"
}

run_cmux_fn() {  # <dir> <snippet>
  PATH="$1/bin:$PATH" FAKE_DIR="$1/fake" FAKE_WIN=$WIN FM_HOME="$1/home" FM_ROOT="$ROOT" \
    bash -c '. "$0/bin/backends/cmux.sh"; eval "$1"' "$ROOT" "$2"
}

new_home() {  # <dir>
  mkdir -p "$1/home/state" "$1/home/config" "$1/home/data"
}

hometag() {  # <dir>
  run_cmux_fn "$1" 'fm_backend_cmux_home_label'
}

write_meta() {  # <dir> <id> <ws> <sf> [extra lines]
  local d=$1 id=$2 ws=$3 sf=$4; shift 4
  {
    echo "window=$ws:$sf"
    echo "backend=cmux"
    echo "cmux_workspace_id=$ws"
    echo "cmux_surface_id=$sf"
    echo "harness=claude"
    echo "kind=ship"
    echo "worktree=$d/wt"
    for l in "$@"; do echo "$l"; done
  } > "$d/home/state/$id.meta"
}

run_heal() {  # <dir> [args]
  local d=$1; shift
  PATH="$d/bin:$PATH" FAKE_DIR="$d/fake" FAKE_WIN=$WIN FM_HOME="$d/home" FM_CMUX_HEAL_SETTLE=2 FM_CMUX_HEAL_WINDOW=0 \
    bash "$ROOT/bin/fm-cmux-reboot-heal.sh" "$@" 2>&1
}

test_agent_state() {
  local d="$TMP_ROOT/state" out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  add_tab "$d" W-LIVE S-LIVE x ttys001 101 claude
  add_tab "$d" W-BARE S-BARE x ttys002 102 -zsh
  add_tab "$d" W-BUSY S-BUSY x ttys003 103 cmux
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(run_cmux_fn "$d" 'for t in W-LIVE:S-LIVE W-BARE:S-BARE W-BUSY:S-BUSY W-GONE:S-GONE; do fm_backend_cmux_agent_state "$t"; echo; done')
  [ "$out" = $'alive\ndead\nunreadable\nmissing' ] || fail "agent states: got '$out'"
  pass "fm_backend_cmux_agent_state: alive, dead (shell only), unreadable (other), missing"
}

test_epoch_gate() {
  local d="$TMP_ROOT/once" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W1 S1 "fm-$tag-a" ttys010 110 claude
  write_meta "$d" a W1 S1
  echo "x" > "$d/fake/screen.S1"
  out=$(run_heal "$d")
  [ -z "$out" ] || fail "first run must be silent: $out"
  [ -s "$d/home/state/.cmux-heal-epoch" ] || fail "first run must record the epoch"
  ! grep -q "read-screen" "$d/fake/log" || fail "first run must not read any tab"
  echo "0 0" > "$d/home/state/.cmux-heal-epoch"
  run_heal "$d" >/dev/null
  grep -q "read-screen" "$d/fake/log" || fail "a new epoch must run a pass"
  [ "$(cat "$d/home/state/.cmux-heal-epoch")" != "0 0" ] || fail "a finished pass must stamp the epoch"
  : > "$d/fake/log"
  out=$(run_heal "$d")
  [ -z "$out" ] || fail "the same epoch must be silent: $out"
  ! grep -q "read-screen" "$d/fake/log" || fail "the same epoch must read no tab"
  FM_CMUX_HEAL=off run_heal "$d" --force >/dev/null
  ! grep -q "read-screen" "$d/fake/log" || fail "FM_CMUX_HEAL=off must disable the pass"
  pass "reboot heal: first run records the epoch, a new epoch heals once, off switch works"
}

test_dry_run_changes_nothing() {
  local d="$TMP_ROOT/dry" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W-NEW S-NEW "fm-$tag-b" ttys022 122 -zsh
  write_meta "$d" b W-OLD S-OLD
  echo '$' > "$d/fake/screen.S-NEW"
  out=$(run_heal "$d" --force --dry-run)
  grep -q '^window=W-OLD:S-OLD$' "$d/home/state/b.meta" || fail "dry run must not rewrite the record"
  ! grep -Eq '^(send|send-key|select-workspace) ' "$d/fake/log" || fail "dry run must send nothing: $(cat "$d/fake/log")"
  printf '%s' "$out" | grep -q 'would restore fm-b' || fail "dry run must report the restore: $out"
  [ ! -f "$d/home/state/.cmux-heal-epoch" ] || fail "dry run must not stamp the epoch"
  pass "reboot heal: --dry-run reports actions and changes nothing"
}

test_prompt_hooks() {
  local d="$TMP_ROOT/hooks" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W9 S9 "fm-$tag-k" ttys070 170 wrapper
  add_tab "$d" W10 S10 "fm-$tag-l" ttys071 171 wrapper
  write_meta "$d" k W9 S9
  write_meta "$d" l W10 S10
  printf 'Your token expired. Refresh now? [y/n]\n' > "$d/fake/screen.S9"
  printf 'Something else? [y/n]\n' > "$d/fake/screen.S10"
  mkdir -p "$d/home/config/cmux-heal-hooks.d"
  cat > "$d/home/config/cmux-heal-hooks.d/token.sh" <<'SH'
fm_heal_hook_token_match() { case "$1" in *'token expired'*) return 0 ;; esac; return 1; }
fm_heal_hook_token_answer() { cmux send --workspace "$1" --surface "$2" n; return 0; }
fm_heal_hook_token_ask() { printf 'refresh the token'; }
SH
  out=$(run_heal "$d" --force)
  grep -q 'send --workspace W9 --surface S9 n' "$d/fake/log" || fail "a matched hook must answer: $(cat "$d/fake/log")"
  printf '%s' "$out" | grep -q 'fm-k: token prompt answered by its hook' || fail "missing hook fact: $out"
  ! grep -Eq '^send(-key)? .*S10' "$d/fake/log" || fail "an unowned prompt must be left alone"
  printf '%s' "$out" | grep -q 'ask: fm-l: a prompt is waiting' || fail "an unowned prompt must raise an ask: $out"
  grep -q 'fm-l' "$d/home/state/cmux-heal-status.md" || fail "asks must land in the status file"
  grep -q '^notify ' "$d/fake/log" || fail "asks must notify once"
  pass "reboot heal: hook seam answers its own prompt; an unowned prompt is an ask, never answered"
}

test_refreshes_endpoint_and_clears_residue() {
  local d="$TMP_ROOT/residue" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W-NEW S-NEW "fm-$tag-b" ttys020 120 claude
  write_meta "$d" b W-OLD S-OLD
  printf '────\n❯\xc2\xa0cmux restore claude 1234\n────\n' > "$d/fake/screen.S-NEW"
  printf '────\n❯\xc2\xa0\n────\n' > "$d/fake/screen-after-bs.S-NEW"
  out=$(run_heal "$d" --force)
  grep -q '^window=W-NEW:S-NEW$' "$d/home/state/b.meta" || fail "endpoint must be rewritten: $(cat "$d/home/state/b.meta")"
  grep -q '^harness=claude$' "$d/home/state/b.meta" || fail "other meta lines must survive"
  printf '%s' "$out" | grep -q 'fm-b: endpoint ids refreshed' || fail "missing refresh fact: $out"
  printf '%s' "$out" | grep -q 'fm-b: cleared restore text' || fail "missing clear fact: $out"
  [ "$(grep -c 'surface S-NEW backspace' "$d/fake/log")" -ge 24 ] || fail "residue must be erased with enough backspaces"
  ! grep -q 'surface S-NEW enter' "$d/fake/log" || fail "a live composer must never get Enter"
  pass "reboot heal: refreshes stale endpoint ids and erases restore text without submitting"
}

test_trust_prompt_only_for_own_copy() {
  local d="$TMP_ROOT/trust" tag
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W3 S3 "fm-$tag-c" ttys030 130 claude
  add_tab "$d" W4 S4 "fm-$tag-e" ttys031 131 claude
  write_meta "$d" c W3 S3
  write_meta "$d" e W4 S4
  printf 'Accessing workspace:\n %s/wt\n ❯ No, exit\n   Yes, I trust this folder\n' "$d" > "$d/fake/screen.S3"
  printf 'Accessing workspace:\n /somewhere/else\n ❯ No, exit\n   Yes, I trust this folder\n' > "$d/fake/screen.S4"
  run_heal "$d" --force >/dev/null
  grep -q 'surface S3 down' "$d/fake/log" || fail "own-copy trust prompt must move to yes"
  grep -q 'surface S3 enter' "$d/fake/log" || fail "own-copy trust prompt must be confirmed"
  ! grep -Eq 'send-key .*surface S4 (down|enter)' "$d/fake/log" || fail "a trust prompt for another folder must be left alone"
  pass "reboot heal: answers folder trust only for the task's own copy"
}

test_bare_shell_restored() {
  local d="$TMP_ROOT/bare" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W5 S5 "fm-$tag-f" ttys040 140 -zsh
  write_meta "$d" f W5 S5
  : > "$d/fake/restore-works.S5"
  echo '$' > "$d/fake/screen.S5"
  out=$(run_heal "$d" --force)
  grep -q 'send --workspace W5 --surface S5 cmux restore --surface' "$d/fake/log" || fail "bare shell must get cmux restore: $(cat "$d/fake/log")"
  printf '%s' "$out" | grep -q 'fm-f: agent back via cmux restore' || fail "missing restore fact: $out"
  pass "reboot heal: brings a bare shell back with cmux restore"
}

test_unrecoverable_left_for_recovery() {
  local d="$TMP_ROOT/left" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W6 S6 "fm-$tag-g" ttys050 150 -zsh
  write_meta "$d" g W6 S6
  echo '$' > "$d/fake/screen.S6"
  write_meta "$d" h W-NONE S-NONE
  out=$(run_heal "$d" --force)
  printf '%s' "$out" | grep -q 'fm-g: no agent after restore or resume; left for dead-endpoint recovery' || fail "missing leftover fact: $out"
  printf '%s' "$out" | grep -q 'fm-h: tab not found' || fail "missing tab-not-found fact: $out"
  pass "reboot heal: reports what it cannot heal and leaves it to recovery"
}

test_unreadable_tab_selected_then_restored() {
  local d="$TMP_ROOT/select" tag
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" W7 S7 "fm-$tag-i" ttys060 160 claude
  add_tab "$d" W8 S8 "other" ttys061 161 -zsh
  jq '(.workspaces[] | select(.id == "W8") | .selected) = true' "$d/fake/workspaces.json" > "$d/fake/w.tmp" && mv "$d/fake/w.tmp" "$d/fake/workspaces.json"
  write_meta "$d" i W7 S7
  : > "$d/fake/unreadable.S7"
  printf '────\n❯\xc2\xa0\n────\n' > "$d/fake/screen.S7"
  run_heal "$d" --force >/dev/null
  grep -q 'select-workspace --workspace W7' "$d/fake/log" || fail "unreadable tab must be selected once"
  grep -q 'select-workspace --workspace W8' "$d/fake/log" || fail "the previous selection must be restored"
  pass "reboot heal: selects an unreadable tab once, then restores the previous selection"
}

test_dead_board_restart_resolves_anchor_ref() {
  local d="$TMP_ROOT/board-restart" tag out
  mkdir -p "$d"; make_fake "$d"; new_home "$d"
  tag=$(hometag "$d")
  add_tab "$d" MGR S-MGR "fm-$tag-manager" ttys080 180 claude
  add_tab "$d" ANCHOR_UUID ANCHOR_SF 'Workers header' ttys081 181 -zsh
  add_tab "$d" WORK S-WORK "fm-$tag-worker" ttys082 182 claude
  jq '(.workspaces[] | select(.id == "ANCHOR_UUID") | .ref) = "workspace:2"' \
    "$d/fake/workspaces.json" > "$d/fake/workspaces.tmp"
  mv "$d/fake/workspaces.tmp" "$d/fake/workspaces.json"
  write_meta "$d" worker WORK S-WORK
  echo MGR > "$d/home/state/.cmux-manager-ws"
  echo workers > "$d/home/config/cmux-layout"
  out=$(run_heal "$d" --force)
  grep -q '^send --workspace ANCHOR_UUID --surface ANCHOR_SF ' "$d/fake/log" || fail "dead board was not restarted at the resolved anchor: $out"
  grep -q '^send-key --workspace ANCHOR_UUID --surface ANCHOR_SF Enter$' "$d/fake/log" || fail 'dead board restart did not submit at the resolved anchor'
  pass 'reboot heal: dead board restart resolves anchor ref to UUID and surface'
}

test_agent_state
test_epoch_gate
test_dry_run_changes_nothing
test_prompt_hooks
test_refreshes_endpoint_and_clears_residue
test_trust_prompt_only_for_own_copy
test_bare_shell_restored
test_unrecoverable_left_for_recovery
test_dead_board_restart_resolves_anchor_ref
test_unreadable_tab_selected_then_restored
