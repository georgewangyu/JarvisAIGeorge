#!/usr/bin/env bash
# tests/fm-supervision-checkpoint-handoff.test.sh - the watcher-liveness guard
# under the Codex foreground-checkpoint supervision model (issue #14).
# Between two bounded checkpoints no watcher process exists by design; that gap
# is the expected manager hand-off while the beacon is fresh and the last
# checkpoint returned normally within the hand-off bound. An abandoned cycle, a
# failed checkpoint, or a stale beacon must still raise the full alarm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-checkpoint-handoff)

new_home() {  # <name> -> home
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/data" "$h/config"
  printf 'window=fm-t1\nendpoint_task_id=t1\nkind=ship\nbackend=tmux\n' > "$h/state/t1.meta"
  printf '%s\n' "$h"
}

old() {  # <path>: make it older than any grace used here
  touch -t 2001011200 "$1"
}

guard() {  # <home> -> stderr of one guard run
  { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISION_MODEL=checkpoint FM_GUARD_GRACE=300 \
    "$ROOT/bin/fm-guard.sh" >/dev/null; } 2>&1
}

test_normal_handoff_is_not_an_outage() {
  local h out
  h=$(new_home handoff)
  touch "$h/state/.last-watcher-beat" "$h/state/.watch-checkpoint-return"
  out=$(guard "$h")
  assert_not_contains "$out" "WATCHER DOWN" "a checkpoint that just returned is the expected hand-off, not an outage"
  assert_contains "$out" "supervision hand-off" "the hand-off must be stated, not silent"
  pass "checkpoint model: a normal checkpoint return reads as a hand-off, not WATCHER DOWN"
}

test_abandoned_cycle_still_alarms() {
  local h out
  h=$(new_home abandoned)
  touch "$h/state/.last-watcher-beat"
  : > "$h/state/.watch-checkpoint-return"
  old "$h/state/.watch-checkpoint-return"
  out=$(FM_CHECKPOINT_HANDOFF_GRACE=60 guard "$h")
  assert_contains "$out" "WATCHER DOWN" "a hand-off older than its bound must alarm"
  pass "checkpoint model: a cycle nobody restarted still raises WATCHER DOWN"
}

test_failed_checkpoint_alarms_at_once() {
  local h out
  h=$(new_home failed)
  touch "$h/state/.last-watcher-beat"
  out=$(guard "$h")
  assert_contains "$out" "WATCHER DOWN" "no normal return on record must alarm even with a fresh beacon"
  pass "checkpoint model: a checkpoint that did not return normally alarms at once"
}

test_stale_beacon_alarms_despite_recent_return() {
  local h out
  h=$(new_home stale)
  : > "$h/state/.last-watcher-beat"
  old "$h/state/.last-watcher-beat"
  touch "$h/state/.watch-checkpoint-return"
  out=$(guard "$h")
  assert_contains "$out" "WATCHER DOWN" "a stale beacon is a lapse whatever the hand-off record says"
  pass "checkpoint model: a stale beacon still alarms"
}

test_other_models_unchanged() {
  local h out
  h=$(new_home persistent)
  touch "$h/state/.last-watcher-beat" "$h/state/.watch-checkpoint-return"
  out=$({ FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_SUPERVISION_MODEL=persistent FM_GUARD_GRACE=300 \
    "$ROOT/bin/fm-guard.sh" >/dev/null; } 2>&1)
  assert_contains "$out" "WATCHER DOWN" "the persistent model must not accept a checkpoint hand-off"
  pass "persistent model: a hand-off record does not relax its live-watcher requirement"
}

test_checkpoint_records_only_normal_returns() {
  local d="$TMP_ROOT/cp" h rc
  h="$d/home"
  mkdir -p "$d/bin" "$h/state"
  cp "$ROOT/bin/fm-watch-checkpoint.sh" "$d/bin/"
  stub() {  # <body>
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$d/bin/fm-watch.sh"
    chmod +x "$d/bin/fm-watch.sh"
  }
  # shellcheck disable=SC2016 # expanded by the stub watcher
  stub 'echo "signal: $FM_HOME/state/t1.status"'
  FM_HOME="$h" "$d/bin/fm-watch-checkpoint.sh" --seconds 5 >/dev/null 2>&1
  assert_present "$h/state/.watch-checkpoint-return" "a wake return must record the hand-off"
  stub 'echo "error: boom" >&2; exit 3'
  FM_HOME="$h" "$d/bin/fm-watch-checkpoint.sh" --seconds 5 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "a failing watcher must keep its exit status, got $rc"
  assert_absent "$h/state/.watch-checkpoint-return" "an abnormal return must clear the hand-off record"
  stub 'sleep 10'
  FM_HOME="$h" "$d/bin/fm-watch-checkpoint.sh" --seconds 1 >/dev/null 2>&1
  assert_present "$h/state/.watch-checkpoint-return" "a quiet checkpoint must record the hand-off"
  pass "foreground checkpoint: records the hand-off on a wake or a quiet return, clears it on failure"
}

test_checkpoint_records_only_normal_returns
test_normal_handoff_is_not_an_outage
test_abandoned_cycle_still_alarms
test_failed_checkpoint_alarms_at_once
test_stale_beacon_alarms_despite_recent_return
test_other_models_unchanged
