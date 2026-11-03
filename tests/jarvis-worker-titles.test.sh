#!/usr/bin/env bash
# tests/jarvis-worker-titles.test.sh - readable worker tab titles (issue #18).
#
# A worker tab reads "◆ <display title>" (for example "◆ Reviewer: Check
# startup flow") instead of "◆ <task-id>". The title is display only: the task
# id and the scoped label fm-<hometag>-<id> in the tab's description stay the
# only identifiers for recovery, routing, teardown, reboot heal and board
# lookups, and two tasks may share a title. A stateful fake cmux records every
# call and lets a rename change the live title.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-worker-titles-tests)
export JARVIS_HOME_POINTER="$TMP_ROOT/home-pointer"
WIN=FAKEWIN
MARK="◆"

# Fake cmux. State in <dir>/fake/ws.json: {"workspaces":[{id,title,description}]}.
make_fake() {  # <dir>
  local d=$1
  mkdir -p "$d/bin" "$d/fake"
  printf '{"workspaces":[{"id":"MGR","title":"JarvisAIGeorge","description":""}]}\n' > "$d/fake/ws.json"
  cat > "$d/bin/cmux" <<'SH'
#!/usr/bin/env bash
F="$FAKE_DIR"
printf '%s\n' "$*" >> "$F/log"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
sub=$1; shift
case "$sub" in
  rpc)
    [ "${1:-}" = system.tree ] || exit 1
    jq -c --arg win "$FAKE_WIN" '{windows:[{id:$win,workspace_count:(.workspaces|length),
      workspaces:[.workspaces[] | . + {panes:[{id:("p-"+.id),surface_count:1,surface_ids:[("s-"+.id)],surfaces:[{id:("s-"+.id)}]}]}]}]}' "$F/ws.json" ;;
  workspace-group)
    case "$1" in
      list) printf '{"groups":[{"ref":"workspace_group:1","name":"JarvisAIGeorge: Workers","anchor_workspace_ref":"workspace:2"}]}\n' ;;
    esac ;;
  workspace-action)
    ws=$(arg --workspace "$@")
    if [ "$(arg --action "$@")" = rename ]; then
      t=$(arg --title "$@")
      jq --arg id "$ws" --arg t "$t" '(.workspaces[] | select(.id == $id) | .title) = $t' "$F/ws.json" > "$F/ws.tmp" && mv "$F/ws.tmp" "$F/ws.json"
    fi ;;
  new-workspace)
    n=$(( $(jq '.workspaces|length' "$F/ws.json") + 1 ))
    jq --arg id "W$n" --arg t "$(arg --name "$@")" --arg d "$(arg --description "$@")" \
      '.workspaces += [{id:$id,title:$t,description:$d}]' "$F/ws.json" > "$F/ws.tmp" && mv "$F/ws.tmp" "$F/ws.json" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$d/bin/cmux"
  mkdir -p "$d/home/state" "$d/home/config" "$d/home/data"
  echo workers > "$d/home/config/cmux-layout"
  echo MGR > "$d/home/state/.cmux-manager-ws"
}

in_cmux() {  # <dir> <snippet>
  PATH="$1/bin:$PATH" FAKE_DIR="$1/fake" FAKE_WIN=$WIN FM_HOME="$1/home" FM_ROOT="$ROOT" \
    bash -c '. "$0/bin/backends/cmux.sh"; eval "$1"' "$ROOT" "$2"
}

title_of() {  # <dir> <ws>
  jq -r --arg id "$2" '.workspaces[] | select(.id == $id) | .title' "$1/fake/ws.json"
}

lib() {  # <snippet>
  bash -c '. "$0/bin/fm-display-title-lib.sh"; eval "$1"' "$ROOT" "$1"
}

test_derivation() {
  local b="$TMP_ROOT/briefs" out
  mkdir -p "$b"
  printf -- '---\nid: r1\ntitle: Check startup flow\n---\n# Objective\nx\n' > "$b/fm.md"
  printf 'You are a crewmate: work alone.\n\n# Task\n## Captain'"'"'s intent\nAdd retry to the upload client\n\n## Firstmate spec\nx\n' > "$b/scaffold.md"
  out=$(lib "fm_display_title r1 george-coding-agent:reviewer '$b/fm.md' ''")
  assert_equals "Reviewer: Check startup flow" "$out" "role from --agent, title from the brief"
  out=$(lib "fm_display_title t2 '' '$b/scaffold.md' ''")
  assert_equals "Add retry to the upload client" "$out" "a scaffold brief uses its first intent line, not its preamble"
  out=$(lib "fm_display_title fix-login coding '$b/missing.md' ''")
  assert_equals "Coding: fix-login" "$out" "no brief falls back to the task id"
  out=$(lib "fm_display_title t3 george-coding-agent:coding '$b/fm.md' 'Port the   parser'")
  assert_equals "Coding: Port the parser" "$out" "an explicit --title wins and is cleaned"
  out=$(lib "fm_display_title t4 code_review '' 'A very long description of the task that goes on and on and on'")
  [ "${#out}" -le 50 ] || fail "title is capped at 50 chars: ${#out} '$out'"
  assert_contains "$out" "Code Review: A very long" "the role is made readable"
  out=$(lib "printf 'display_title=Kept title\n' > '$b/r.meta'; fm_display_title_resolve r1 coding '$b/fm.md' '' '$b/r.meta'")
  assert_equals "Kept title" "$out" "a relaunch keeps the recorded title"
  out=$(lib "fm_display_title_resolve r1 coding '$b/fm.md' 'New one' '$b/r.meta'")
  assert_equals "Coding: New one" "$out" "an explicit --title replaces it on relaunch"
  out=$("$ROOT/bin/fm-spawn.sh" t1 /tmp --title 2>&1); expect_code 1 "$?" "fm-spawn --title without a value"
  assert_contains "$out" "--title requires a value" "fm-spawn parses --title"
  pass "titles: explicit, brief title, intent line, id fallback, readable role, 50-char cap, kept on relaunch"
}

test_spawn_create_with_and_without_title() {
  local d="$TMP_ROOT/create" tag
  make_fake "$d"
  tag=$(in_cmux "$d" 'fm_backend_cmux_home_label')
  FM_CMUX_DISPLAY_TITLE="Reviewer: Check startup flow" in_cmux "$d" "fm_cmux_layout_create fm-$tag-r1 /tmp" || fail "create with a title"
  in_cmux "$d" "fm_cmux_layout_create fm-$tag-r2 /tmp" || fail "create without a title"
  assert_equals "$MARK Reviewer: Check startup flow" "$(jq -r --arg l "fm-$tag-r1" '.workspaces[] | select(.description == $l) | .title' "$d/fake/ws.json")" "a titled worker tab"
  assert_equals "$MARK r2" "$(jq -r --arg l "fm-$tag-r2" '.workspaces[] | select(.description == $l) | .title' "$d/fake/ws.json")" "an untitled worker keeps the id"
  pass "spawn create: the tab reads '$MARK <title>' with a title and '$MARK <id>' without; the label stays in the description"
}

test_duplicate_titles_distinct_by_id() {
  local d="$TMP_ROOT/dup" tag a b
  make_fake "$d"
  tag=$(in_cmux "$d" 'fm_backend_cmux_home_label')
  FM_CMUX_DISPLAY_TITLE="Coding: Fix tests" in_cmux "$d" "fm_cmux_layout_create fm-$tag-a /tmp"
  FM_CMUX_DISPLAY_TITLE="Coding: Fix tests" in_cmux "$d" "fm_cmux_layout_create fm-$tag-b /tmp"
  a=$(in_cmux "$d" "fm_backend_cmux_workspace_id_for_label fm-$tag-a")
  b=$(in_cmux "$d" "fm_backend_cmux_workspace_id_for_label fm-$tag-b")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || fail "two tasks with one title resolve to two tabs by label (a=$a b=$b)"
  [ -z "$(in_cmux "$d" "fm_backend_cmux_workspace_id_for_label '$MARK Coding: Fix tests'")" ] \
    || fail "a shared display title must never resolve to a task"
  pass "duplicate titles: each task still resolves to its own tab by label; the title resolves to nothing"
}

test_board_shows_and_keeps_title() {
  local d="$TMP_ROOT/board" tag stub out ws
  make_fake "$d"
  tag=$(in_cmux "$d" 'fm_backend_cmux_home_label')
  FM_CMUX_DISPLAY_TITLE="Reviewer: Check startup flow" in_cmux "$d" "fm_cmux_layout_create fm-$tag-r1 /tmp"
  ws=$(jq -r --arg l "fm-$tag-r1" '.workspaces[] | select(.description == $l) | .id' "$d/fake/ws.json")
  printf 'backend=cmux\ncmux_workspace_id=%s\nkind=ship\ndisplay_title=Reviewer: Check startup flow\n' "$ws" > "$d/home/state/r1.meta"
  stub="$d/stub.sh"
  printf '#!/usr/bin/env bash\necho "state: working · source: pane · x"\n' > "$stub"
  chmod +x "$stub"
  out=$(FM_HOME="$d/home" FM_CREW_STATE_BIN="$stub" bash "$ROOT/bin/fm-cmux-board.sh" --once)
  assert_contains "$out" "Reviewer: Check startup flow" "the board shows the display title"
  assert_contains "$out" "r1" "the board still shows the task id"
  # cmux (or an agent) retitles the tab; the next board pass puts it back.
  jq --arg id "$ws" '(.workspaces[] | select(.id == $id) | .title) = "claude: some auto name"' "$d/fake/ws.json" > "$d/fake/t" && mv "$d/fake/t" "$d/fake/ws.json"
  PATH="$d/bin:$PATH" FAKE_DIR="$d/fake" FAKE_WIN=$WIN FM_HOME="$d/home" FM_CREW_STATE_BIN="$stub" FM_CMUX_BOARD_INTERVAL=0 \
    bash "$ROOT/bin/fm-cmux-board.sh" --passes 1 >/dev/null
  assert_equals "$MARK Reviewer: Check startup flow" "$(title_of "$d" "$ws")" "the board restores the title after an auto-retitle"
  : > "$d/fake/log"
  PATH="$d/bin:$PATH" FAKE_DIR="$d/fake" FAKE_WIN=$WIN FM_HOME="$d/home" FM_CREW_STATE_BIN="$stub" FM_CMUX_BOARD_INTERVAL=0 \
    bash "$ROOT/bin/fm-cmux-board.sh" --passes 1 >/dev/null
  ! grep -q 'action rename' "$d/fake/log" || fail "a tab that already reads its title is not renamed again"
  pass "board: shows the display title, restores it after cmux retitles the tab, and leaves a correct tab alone"
}

# Heal finds the tab by its label even when the tab shows a title, retitles it,
# and teardown's lookup (the same label resolver) never matches a title.
test_heal_and_teardown_use_label() {
  local d="$TMP_ROOT/heal" tag ws out
  make_fake "$d"
  tag=$(in_cmux "$d" 'fm_backend_cmux_home_label')
  in_cmux "$d" "fm_cmux_layout_create fm-$tag-h1 /tmp"
  ws=$(jq -r --arg l "fm-$tag-h1" '.workspaces[] | select(.description == $l) | .id' "$d/fake/ws.json")
  jq --arg id "$ws" '(.workspaces[] | select(.id == $id) | .title) = "after a reboot"' "$d/fake/ws.json" > "$d/fake/t" && mv "$d/fake/t" "$d/fake/ws.json"
  # A decoy tab whose TITLE is the task's display title but carries no label.
  jq '.workspaces += [{id:"DECOY",title:"◆ Ops: Heal me",description:""}]' "$d/fake/ws.json" > "$d/fake/t" && mv "$d/fake/t" "$d/fake/ws.json"
  out=$(in_cmux "$d" "fm_backend_cmux_workspace_id_for_label fm-$tag-h1")
  assert_equals "$ws" "$out" "the label resolves the task's own tab, never the decoy with its title"
  ALL=$(in_cmux "$d" 'fm_backend_cmux_all_workspaces_json')
  out=$(in_cmux "$d" "ALL='$ALL'; fm_cmux_layout_apply_title '$ws' '$WIN' \"\$(fm_cmux_layout_task_title h1 'Ops: Heal me')\" 'after a reboot'")
  assert_equals "$MARK Ops: Heal me" "$(title_of "$d" "$ws")" "the heal retitle sets the display title"
  assert_equals "◆ Ops: Heal me" "$(title_of "$d" DECOY)" "the decoy is untouched"
  grep -q 'display_title' "$ROOT/bin/fm-cmux-reboot-heal.sh" || fail "reboot heal applies the recorded title"
  ! grep -q 'display_title' "$ROOT/bin/fm-teardown.sh" || fail "teardown must not look at the display title"
  # shellcheck disable=SC2016 # a literal jq pattern
  ! grep -Eq 'select\(\.title == \$(want|l|t)' "$ROOT/bin/fm-display-title-lib.sh" || fail "the title lib must not look tasks up"
  pass "heal and teardown: the label finds the tab even when a decoy shows the same title; heal retitles by label"
}

test_derivation
test_spawn_create_with_and_without_title
test_duplicate_titles_distinct_by_id
test_board_shows_and_keeps_title
test_heal_and_teardown_use_label
