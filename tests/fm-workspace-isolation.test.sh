#!/usr/bin/env bash
# Proves workspace-isolation mode resolution, spawn routing, and shared-checkout cleanup safety.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=bin/fm-workspace-lib.sh
. "$ROOT/bin/fm-workspace-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-workspace-isolation.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

make_project_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name 'Test User'
  printf 'base\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m base
}

make_spawn_case() {
  local name=$1 mode=${2:-}
  local home="$TMP_ROOT/$name/home" proj="$TMP_ROOT/$name/project" fakebin
  fm_test_spawn_home "$home"
  make_project_repo "$proj"
  proj=$(cd "$proj" && pwd -P)
  if [ -n "$mode" ] && [ "$mode" != bogus ]; then
    printf '%s\n' "$mode" > "$home/config/workspace-isolation"
  fi
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-brief.sh" task-a project --mode direct-PR >/dev/null
  python3 - "$home/data/task-a/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('{TASK}', 'Change the fixture.')
s = s.replace('{FIRSTMATE_SPEC}', 'Exercise the spawn behavior under test.')
p.write_text(s)
PY
  if [ "$mode" = bogus ]; then
    printf '%s\n' "$mode" > "$home/config/workspace-isolation"
  fi
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/$name" codex gh gh-axi no-mistakes)
  printf '%s\t%s\t%s\n' "$home" "$proj" "$fakebin"
}

run_spawn_case() {
  local home=$1 proj=$2 fakebin=$3 pane=$4 log=$5 pane_log=$6 id=${7:-task-a}
  FM_FAKE_LAUNCH_LOG="$log" FM_FAKE_PANE_LOG="$pane_log" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" "$id" "$proj" codex --mode direct-PR --yolo off
}

test_mode_resolver_defaults_and_rejects_invalid() {
  local config="$TMP_ROOT/config-resolve"
  mkdir -p "$config"
  [ "$(fm_workspace_isolation_mode "$config")" = shared-checkout ] || fail 'absent workspace-isolation did not default to shared-checkout'
  printf 'worktree\n' > "$config/workspace-isolation"
  [ "$(fm_workspace_isolation_mode "$config")" = worktree ] || fail 'explicit worktree did not resolve'
  printf 'bogus\n' > "$config/workspace-isolation"
  if out=$(fm_workspace_isolation_mode "$config" 2>&1); then
    fail 'invalid workspace-isolation was accepted'
  fi
  assert_contains "$out" 'invalid config/workspace-isolation' 'invalid workspace-isolation was not explained clearly'
  pass 'workspace isolation config defaults, accepts worktree, and rejects invalid values'
}

test_shared_spawn_uses_project_without_treehouse_or_branch() {
  local rec home proj fakebin out log pane_log meta brief
  rec=$(make_spawn_case shared-default)
  IFS=$'\t' read -r home proj fakebin <<< "$rec"
  log="$TMP_ROOT/shared-default/launch.log"
  pane_log="$TMP_ROOT/shared-default/pane.log"
  out=$(run_spawn_case "$home" "$proj" "$fakebin" "$proj" "$log" "$pane_log") || fail "shared spawn failed: $out"
  meta="$home/state/task-a.meta"
  assert_contains "$out" "worktree=$proj" 'shared spawn did not report the project path as its worktree'
  assert_contains "$(cat "$meta")" 'workspace_isolation=shared-checkout' 'shared spawn did not record shared-checkout mode'
  assert_not_contains "$(cat "$pane_log" 2>/dev/null || true)" 'treehouse get' 'shared spawn invoked treehouse get'
  assert_not_contains "$(cat "$pane_log" 2>/dev/null || true)" 'FM_TASK_ID=' 'shared spawn exported task worktree marker'
  brief="$home/data/task-a/launch-brief.md"
  assert_contains "$(cat "$brief")" 'do not create a branch or Git worktree' 'shared launch brief did not forbid branch/worktree creation'
  assert_not_contains "$(cat "$brief")" 'git checkout -b' 'shared launch brief still creates a branch'
  pass 'shared-checkout spawn uses the canonical checkout and does not invoke worktree or branch setup'
}

test_explicit_worktree_spawn_preserves_legacy_treehouse_path() {
  local rec home proj fakebin clone out log pane_log meta
  rec=$(make_spawn_case explicit-worktree worktree)
  IFS=$'\t' read -r home proj fakebin <<< "$rec"
  clone="$TMP_ROOT/explicit-worktree/ordinary-copy"
  git clone -q "$proj" "$clone"
  log="$TMP_ROOT/explicit-worktree/launch.log"
  pane_log="$TMP_ROOT/explicit-worktree/pane.log"
  out=$(run_spawn_case "$home" "$proj" "$fakebin" "$clone" "$log" "$pane_log") || fail "worktree-mode spawn failed: $out"
  meta="$home/state/task-a.meta"
  assert_contains "$(cat "$pane_log")" 'treehouse get' 'worktree mode did not invoke treehouse get'
  assert_contains "$(cat "$meta")" "worktree=$clone" 'worktree mode did not use the isolated path reported by the backend'
  assert_contains "$(cat "$meta")" 'workspace_isolation=worktree' 'worktree mode did not record its mode'
  assert_contains "$(cat "$home/data/task-a/launch-brief.md")" 'git checkout -b fm/task-a' 'worktree-mode brief no longer preserves legacy branch instruction'
  pass 'explicit worktree mode keeps the legacy Treehouse-backed behavior'
}

test_invalid_setting_refuses_spawn_before_metadata() {
  local rec home proj fakebin out
  rec=$(make_spawn_case invalid-mode bogus)
  IFS=$'\t' read -r home proj fakebin <<< "$rec"
  if out=$(run_spawn_case "$home" "$proj" "$fakebin" "$proj" "$TMP_ROOT/invalid-mode/launch.log" "$TMP_ROOT/invalid-mode/pane.log" 2>&1); then
    fail "invalid workspace-isolation spawn succeeded: $out"
  fi
  assert_contains "$out" 'invalid config/workspace-isolation' 'invalid spawn refusal did not name workspace-isolation'
  assert_absent "$home/state/task-a.meta" 'invalid workspace-isolation wrote metadata'
  pass 'invalid workspace-isolation refuses spawn clearly before metadata publication'
}

test_shared_teardown_does_not_delete_or_reset_checkout() {
  local home="$TMP_ROOT/teardown/home" proj="$TMP_ROOT/teardown/project" fakebin log out meta
  fm_test_spawn_home "$home"
  make_project_repo "$proj"
  mkdir -p "$home/state" "$home/data"
  meta="$home/state/task-a.meta"
  printf '%s\n' \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$proj" \
    "project=$proj" \
    'harness=codex' \
    'kind=ship' \
    'mode=direct-PR' \
    'yolo=off' \
    'tasktmp=' \
    'model=default' \
    'effort=default' \
    'spawn_gen=test' \
    'workspace_isolation=shared-checkout' > "$meta"
  printf 'worker change\n' > "$proj/worker.txt"
  fakebin=$(make_stubs "$TMP_ROOT/teardown")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_GIT_LOG"
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_TREEHOUSE_LOG"
exit 1
SH
  chmod +x "$fakebin/git" "$fakebin/treehouse"
  log="$TMP_ROOT/teardown/git.log"
  out=$(FM_GIT_LOG="$log" FM_TREEHOUSE_LOG="$TMP_ROOT/teardown/treehouse.log" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEARDOWN_GUARD_DONE=1 PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-a 2>&1) || fail "shared teardown failed: $out"
  assert_present "$proj/worker.txt" 'shared teardown deleted a file in the shared checkout'
  assert_absent "$meta" 'shared teardown did not remove task metadata after safe cleanup'
  assert_not_contains "$(cat "$log" 2>/dev/null || true)" 'reset' 'shared teardown ran git reset'
  assert_not_contains "$(cat "$log" 2>/dev/null || true)" 'checkout' 'shared teardown ran git checkout'
  assert_not_contains "$(cat "$log" 2>/dev/null || true)" 'branch' 'shared teardown ran git branch'
  assert_not_contains "$(cat "$TMP_ROOT/teardown/treehouse.log" 2>/dev/null || true)" 'return' 'shared teardown returned a Treehouse slot'
  pass 'shared-checkout teardown closes records without deleting, resetting, branching, or returning the checkout'
}

test_mode_resolver_defaults_and_rejects_invalid
test_shared_spawn_uses_project_without_treehouse_or_branch
test_explicit_worktree_spawn_preserves_legacy_treehouse_path
test_invalid_setting_refuses_spawn_before_metadata
test_shared_teardown_does_not_delete_or_reset_checkout
