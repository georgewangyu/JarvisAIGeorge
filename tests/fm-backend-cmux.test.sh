#!/usr/bin/env bash
# tests/fm-backend-cmux.test.sh - fake-cmux-CLI unit tests for the cmux
# session-provider adapter (bin/backends/cmux.sh), verified against the real
# cmux 0.64.17 binary (docs/cmux-backend.md). Mirrors
# tests/fm-backend-zellij.test.sh's/tests/fm-backend-herdr.test.sh's
# fakebin/command-log convention: a small, LOG-based, canned-response fake
# `cmux` + real `jq` (jq is a real required tool for this backend, not
# faked). The real-binary smoke test lives in
# tests/fm-backend-cmux-smoke.test.sh, gated on the cmux binary actually
# being installed and reachable.
set -u
# These canned CLI sequences exercise the plain adapter, independent of the
# operator's live layout preference. Layout behavior has its own suite.
export FM_CMUX_LAYOUT=off

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tests)

# make_cmux_fakebin: a `cmux` stub that logs every invocation (one line,
# unit-separated args, to $FM_CMUX_LOG) and returns the canned response for
# that call read from $FM_CMUX_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...), mirroring
# tests/fm-backend-zellij.test.sh's make_zellij_fakebin. A missing response
# file means "succeed with empty stdout" (new-workspace/send/send-key/
# close-* are silent on success on the real CLI). `version` and `ping` are
# handled specially (not call-counted, not consuming the ordered response
# queue) since fm_backend_cmux_version_check/fm_backend_cmux_ping_state are
# called at points a test may not want to hand-count, exactly mirroring
# zellij's --version/list-sessions special-casing.
make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
RESP="${FM_CMUX_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'CMUX_SOCKET_PASSWORD=%s' "${CMUX_SOCKET_PASSWORD:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "${1:-}" = version ]; then
  printf 'cmux %s (97) [abcdef1]\n' "${FM_CMUX_FAKE_VERSION:-0.64.17}"
  exit 0
fi
if [ "${1:-}" = ping ]; then
  printf '%s\n' "${FM_CMUX_FAKE_PING:-PONG}"
  exit "${FM_CMUX_FAKE_PING_EXIT:-0}"
fi

next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

# A direct system.tree RPC fixture. Three arguments per workspace: UUID,
# title, surface UUID. The one-window helper keeps lifecycle tests focused on
# native method provenance rather than CLI tree's silent fallback.
cmux_tree_response() {  # <dir> <n> <window-id> [<ws-id> <title> <surface-id> ...]
  local dir=$1 n=$2 win=$3 id title sf
  shift 3
  jq -n --arg win "$win" '{windows:[{id:$win,workspace_count:0,workspaces:[]}]}' > "$dir/responses/$n.out"
  while [ $# -ge 3 ]; do
    id=$1 title=$2 sf=$3; shift 3
    jq --arg id "$id" --arg title "$title" --arg sf "$sf" '
      .windows[0].workspaces += [{id:$id,title:$title,description:null,
        panes:[{id:("pane-"+$id),surface_count:1,surface_ids:[$sf],
          selected_surface_id:$sf,surfaces:[{id:$sf}]}]}]
      | .windows[0].workspace_count = (.windows[0].workspaces|length)
    ' "$dir/responses/$n.out" > "$dir/responses/$n.tmp"
    mv "$dir/responses/$n.tmp" "$dir/responses/$n.out"
  done
}

cmux_panes_response() {  # <dir> <n> <surface_id>
  printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$3" "$3" > "$1/responses/$2.out"
}

cmux_panes_empty_response() {  # <dir> <n>
  printf '{"panes":[]}' > "$1/responses/$2.out"
}

cmux_read_screen_response() {  # <dir> <n> <text>
  jq -n --arg t "$3" '{text:$t}' > "$1/responses/$2.out"
}

cmux_expected_root_hash() {  # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

cmux_expected_home_label() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(cmux_expected_root_hash "$root")"
}

cmux_expected_scoped_title() {  # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(cmux_expected_home_label "$home" "$root")" "$rest"
}

cmux_assert_call_order() {
  local log=$1 before=$2 after=$3 msg=$4 before_line after_line
  before_line=$(grep -anF -- "$before" "$log" | head -1 | cut -d: -f1)
  after_line=$(grep -anF -- "$after" "$log" | head -1 | cut -d: -f1)
  [ -n "$before_line" ] || fail "$msg (missing before call: '$before')"
  [ -n "$after_line" ] || fail "$msg (missing after call: '$after')"
  [ "$before_line" -lt "$after_line" ] || fail "$msg"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.64.17 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept 0.64.17 (the verified minimum)"
  pass "fm_backend_cmux_version_check: accepts the verified minimum (0.64.17)"
}

test_version_check_accepts_newer_version() {
  local dir fb status
  dir="$TMP_ROOT/version-newer"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.70.0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept a newer minor (0.70.0)"
  pass "fm_backend_cmux_version_check: accepts a newer version (0.70.0)"
}

test_version_check_refuses_old_version() {
  local dir fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_VERSION=0.50.0 \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.50.0 (below the 0.64 minimum)"
  assert_contains "$out" "0.50.0" "version_check error did not name the rejected version"
  pass "fm_backend_cmux_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_cmux() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  # FM_BACKEND_CMUX_BUNDLE_BIN must also be overridden to a nonexistent path:
  # this test may run on a machine (like the one that verified this adapter)
  # where cmux really is installed at the real bundle path, which the plain
  # PATH-emptying above would not hide.
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" FM_BACKEND_CMUX_BUNDLE_BIN="$dir/no-such-cmux" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when cmux is not installed"
  assert_contains "$out" "not found" "version_check did not report cmux as missing"
  pass "fm_backend_cmux_version_check: refuses loudly when cmux is not found on PATH or at the bundle path"
}

# --- password resolution -------------------------------------------------

test_password_reads_from_config_file() {
  local dir out
  dir="$TMP_ROOT/password-file"; mkdir -p "$dir/config"
  printf 'sekret-pw\n' > "$dir/config/cmux-socket-password"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = "sekret-pw" ] || fail "password should be read from config/cmux-socket-password, got '$out'"
  pass "fm_backend_cmux_password: reads the first non-empty line of config/cmux-socket-password"
}

test_password_preserves_config_file_whitespace() {
  local dir out
  dir="$TMP_ROOT/password-file-whitespace"; mkdir -p "$dir/config"
  printf '\nsek ret\t pw  \n' > "$dir/config/cmux-socket-password"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = $'sek ret\t pw  ' ] || fail "password should preserve spaces and tabs from config/cmux-socket-password, got '$out'"
  pass "fm_backend_cmux_password: preserves spaces and tabs in config/cmux-socket-password"
}

test_password_respects_config_override() {
  local dir home_cfg override_cfg out
  dir="$TMP_ROOT/password-config-override"; home_cfg="$dir/home/config"; override_cfg="$dir/override-config"
  mkdir -p "$home_cfg" "$override_cfg"
  printf 'home-pw\n' > "$home_cfg/cmux-socket-password"
  printf 'override-pw\n' > "$override_cfg/cmux-socket-password"
  out=$( FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$override_cfg" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ "$out" = "override-pw" ] || fail "password should be read from FM_CONFIG_OVERRIDE, got '$out'"
  pass "fm_backend_cmux_password: respects FM_CONFIG_OVERRIDE"
}

test_password_empty_when_config_absent() {
  local dir out
  dir="$TMP_ROOT/password-absent"; mkdir -p "$dir/config"
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_password' "$ROOT" )
  [ -z "$out" ] || fail "password should be empty when config/cmux-socket-password is absent, got '$out'"
  pass "fm_backend_cmux_password: empty when config/cmux-socket-password is absent"
}

test_cli_exports_password_only_when_configured() {
  local dir fb
  dir="$TMP_ROOT/password-export"; mkdir -p "$dir/config" "$dir/responses"
  printf 'sekret-pw\n' > "$dir/config/cmux-socket-password"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_HOME="$dir" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_cli ping' "$ROOT" >/dev/null
  assert_contains "$(cat "$dir/log")" "CMUX_SOCKET_PASSWORD=sekret-pw" \
    "fm_backend_cmux_cli did not export the configured password"
  pass "fm_backend_cmux_cli: exports CMUX_SOCKET_PASSWORD when config/cmux-socket-password is set"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/cmux.sh"
    fm_backend_cmux_parse_target "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222" || exit 1
    [ "$FM_BACKEND_CMUX_WORKSPACE" = "11111111-1111-1111-1111-111111111111" ] || { echo "workspace mismatch: $FM_BACKEND_CMUX_WORKSPACE" >&2; exit 1; }
    [ "$FM_BACKEND_CMUX_SURFACE" = "22222222-2222-2222-2222-222222222222" ] || { echo "surface mismatch: $FM_BACKEND_CMUX_SURFACE" >&2; exit 1; }
  ) || fail "fm_backend_cmux_parse_target did not split workspace:surface correctly"
  pass "fm_backend_cmux_parse_target: splits '<workspace_uuid>:<surface_uuid>' on the first colon"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/cmux.sh"
    [ "$(fm_backend_cmux_normalize_key Enter)" = enter ] || { echo "Enter failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key Escape)" = escape ] || { echo "Escape failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key Esc)" = escape ] || { echo "Esc failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key C-c)" = ctrl-c ] || { echo "C-c failed" >&2; exit 1; }
    [ "$(fm_backend_cmux_normalize_key ctrl+c)" = ctrl-c ] || { echo "ctrl+c failed" >&2; exit 1; }
  ) || fail "fm_backend_cmux_normalize_key did not map firstmate's key vocabulary to cmux's verified names"
  pass "fm_backend_cmux_normalize_key: Enter/Escape/C-c map to cmux's verified enter/escape/ctrl-c"
}

test_scoped_title_uses_primary_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-primary"; mkdir -p "$dir"
  expected=$(cmux_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "primary scoped title should be $expected, got '$out'"
  pass "fm_backend_cmux_scoped_title: scopes a primary task title with firstmate plus root hash"
}

test_scoped_title_uses_secondmate_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-title-secondmate"; mkdir -p "$dir"
  printf 'sm-one\n' > "$dir/.fm-secondmate-home"
  expected=$(cmux_expected_scoped_title fm-task1 "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out" = "$expected" ] || fail "secondmate scoped title should be $expected, got '$out'"
  pass "fm_backend_cmux_scoped_title: scopes a secondmate task title with the home marker plus root hash"
}

test_scoped_title_changes_with_root_path() {
  local dir home root_one root_two out_one out_two expected_one expected_two
  dir="$TMP_ROOT/scoped-title-root-hash"; home="$dir/home"; root_one="$dir/root-one"; root_two="$dir/root-two"
  mkdir -p "$home" "$root_one" "$root_two"
  expected_one=$(cmux_expected_scoped_title fm-task1 "$home" "$root_one")
  expected_two=$(cmux_expected_scoped_title fm-task1 "$home" "$root_two")
  out_one=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_one" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  out_two=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_two" bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_scoped_title fm-task1' "$ROOT" )
  [ "$out_one" = "$expected_one" ] || fail "scoped title should include root-one hash as $expected_one, got '$out_one'"
  [ "$out_two" = "$expected_two" ] || fail "scoped title should include root-two hash as $expected_two, got '$out_two'"
  [ "$out_one" != "$out_two" ] || fail "scoped titles should differ for distinct FM_ROOT paths"
  pass "fm_backend_cmux_scoped_title: includes the resolved FM_ROOT hash in the home label"
}

# --- dispatch wiring (fm-backend.sh) ------------------------------------------

test_dispatch_routes_cmux_backend() {
  fm_backend_validate cmux 2>/dev/null || fail "fm_backend_validate should accept cmux"
  pass "fm_backend_validate: cmux is a known backend"
}

test_dispatch_busy_state_unknown_for_cmux() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state cmux '11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for cmux (no native agent-state primitive)"
  pass "fm_backend_busy_state: cmux (no native primitive) always reports unknown, same as tmux/zellij/orca"
}

test_dispatch_composer_state_routes_cmux() {
  local dir fb out target
  dir="$TMP_ROOT/dispatch-composer"; mkdir -p "$dir/responses"
  target="aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state cmux "$1"' "$ROOT" "$target" )
  [ "$out" = pending ] || fail "fm_backend_composer_state should route cmux to its classifier, got '$out'"
  pass "fm_backend_composer_state: routes cmux to the cmux composer classifier"
}

# --- ping_state / ensure_running ---------------------------------------------

test_ping_state_ok() {
  local dir fb out
  dir="$TMP_ROOT/ping-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING=PONG \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = ok ] || fail "ping_state should report ok on PONG, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'ok' on PONG"
}

test_ping_state_denied() {
  local dir fb out
  dir="$TMP_ROOT/ping-denied"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Access denied - only processes started inside cmux can connect" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = denied ] || fail "ping_state should report denied on the cmuxOnly rejection text, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'denied' when socketControlMode=cmuxOnly rejects the connection"
}

test_ping_state_unauth() {
  local dir fb out
  dir="$TMP_ROOT/ping-unauth"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Authentication required - send auth <password> first" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = unauth ] || fail "ping_state should report unauth when no password was presented, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'unauth' when password mode rejects a missing/wrong password"
}

test_ping_state_invalid_password() {
  local dir fb out
  dir="$TMP_ROOT/ping-invalid-pw"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Invalid password" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = unauth ] || fail "ping_state should report unauth on the wrong-password rejection text, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'unauth' when password mode rejects a wrong password (Invalid password)"
}

test_ping_state_down() {
  local dir fb out
  dir="$TMP_ROOT/ping-down"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: Socket not found at /home/x/.local/state/cmux/cmux.sock" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ping_state' "$ROOT" )
  [ "$out" = down ] || fail "ping_state should report down when the socket does not exist yet, got '$out'"
  pass "fm_backend_cmux_ping_state: reports 'down' when the app is not running yet"
}

test_ensure_running_returns_immediately_when_already_ok() {
  local dir fb status
  dir="$TMP_ROOT/ensure-ok"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "open should not be called when cmux is already reachable" >&2
exit 1
SH
  chmod +x "$fb/open"
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING=PONG \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT"
  status=$?
  expect_code 0 "$status" "ensure_running should succeed immediately when already reachable"
  pass "fm_backend_cmux_ensure_running: returns immediately when cmux is already reachable"
}

test_ensure_running_fails_fast_on_denied_without_launching() {
  local dir fb out status
  dir="$TMP_ROOT/ensure-denied"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "LAUNCHED" >> "${FM_CMUX_LAUNCH_MARKER:?}"
exit 0
SH
  chmod +x "$fb/open"
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Access denied - only processes started inside cmux can connect" \
    FM_CMUX_LAUNCH_MARKER="$dir/launched" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "ensure_running should refuse when the socket is denied (relaunching cannot fix a config problem)"
  [ ! -f "$dir/launched" ] || fail "ensure_running should not attempt to launch cmux on a denied socket"
  assert_contains "$out" "docs/cmux-backend.md" "ensure_running's denied error did not point at the setup docs"
  assert_contains "$out" "Automation mode" "ensure_running's denied error did not name the recommended Automation mode"
  assert_contains "$out" "Password mode" "ensure_running's denied error did not name the Password mode alternative"
  assert_contains "$out" "Full open access" "ensure_running's denied error did not name (and caveat) Full open access"
  pass "fm_backend_cmux_ensure_running: fails fast on a denied socket without attempting to launch, naming every viable mode"
}

test_ensure_running_fails_fast_on_unauth_without_launching() {
  local dir fb out status
  dir="$TMP_ROOT/ensure-unauth"; mkdir -p "$dir/responses"
  fb=$(make_cmux_fakebin "$dir")
  cat > "$fb/open" <<'SH'
#!/usr/bin/env bash
echo "LAUNCHED" >> "${FM_CMUX_LAUNCH_MARKER:?}"
exit 0
SH
  chmod +x "$fb/open"
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_FAKE_PING_EXIT=1 \
    FM_CMUX_FAKE_PING="Error: ERROR: Authentication required - send auth <password> first" \
    FM_CMUX_LAUNCH_MARKER="$dir/launched" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_ensure_running' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "ensure_running should refuse when the socket is unauthenticated (relaunching cannot fix a password problem)"
  [ ! -f "$dir/launched" ] || fail "ensure_running should not attempt to launch cmux on an unauthenticated socket"
  assert_contains "$out" "config/cmux-socket-password" "ensure_running's unauth error did not name the password config file"
  assert_contains "$out" "Automation mode" "ensure_running's unauth error did not name the recommended no-password Automation mode"
  assert_contains "$out" "docs/cmux-backend.md" "ensure_running's unauth error did not point at the setup docs"
  pass "fm_backend_cmux_ensure_running: fails fast on an unauthenticated socket, naming the password config and the Automation mode alternative"
}

# --- create_task: duplicate refusal, id resolution ---------------------------

test_create_task_refuses_duplicate_label() {
  local dir fb out status title
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-dup1)
  cmux_tree_response "$dir" 1 window-1 "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" "$title" surface-1
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing workspace title (cmux itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  pass "fm_backend_cmux_create_task: refuses a duplicate workspace title (cmux's own new-workspace has no uniqueness check)"
}

test_create_task_refuses_other_window_duplicate() {
  local dir fb title out rc
  dir="$TMP_ROOT/dup-other-window"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-crosswindow)
  cmux_tree_response "$dir" 1 window-1 other independent other-surface
  jq --arg t "$title" '
    .windows += [{id:"window-2",workspace_count:1,workspaces:[
      {id:"task-in-other-window",title:$t,description:null,
       panes:[{id:"other-pane",surface_count:1,surface_ids:["other-window-surface"],
         surfaces:[{id:"other-window-surface"}]}]}]}]
  ' "$dir/responses/1.out" > "$dir/responses/1.tmp" && mv "$dir/responses/1.tmp" "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  for layout in off workers; do
    printf 0 > "$dir/responses/.count"
    out=$(PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" FM_CMUX_LAYOUT="$layout" \
      bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-crosswindow /tmp/proj' "$ROOT" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$layout create ignored the other-window scoped label"
    assert_contains "$out" 'already exists' "$layout create did not report the duplicate"
  done
  assert_no_grep 'new-workspace' "$dir/log" 'other-window duplicate reached creation'
  pass 'cmux create: plain and grouped preflight checks every native window'
}

test_create_task_refuses_native_failure_and_count_mismatch() {
  local dir fb mode out rc
  for mode in no-native count-mismatch; do
    dir="$TMP_ROOT/create-$mode"; mkdir -p "$dir/responses"
    cmux_tree_response "$dir" 1 window-1 other independent other-surface
    if [ "$mode" = count-mismatch ]; then
      jq '.windows[0].workspace_count = 2' "$dir/responses/1.out" > "$dir/responses/1.tmp"
      mv "$dir/responses/1.tmp" "$dir/responses/1.out"
    else
      printf 1 > "$dir/responses/1.exit"
    fi
    fb=$(make_cmux_fakebin "$dir")
    out=$(PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
      bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-crosswindow /tmp/proj' "$ROOT" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "create accepted $mode"
    assert_no_grep 'new-workspace' "$dir/log" "create mutated after $mode"
    assert_no_grep $'\x1f''tree' "$dir/log" "create used CLI tree fallback after $mode"
  done
  pass 'cmux create: native method failure and count mismatch fail closed without CLI fallback'
}

test_create_task_creates_and_parses_ids() {
  local dir fb out title
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-newtask)
  # 1: native app-wide tree (pre-create duplicate check) -> no match
  cmux_tree_response "$dir" 1 window-1 other independent other-surface
  # 2: new-workspace (silent on success)
  # 3: native app-wide tree (post-create id resolution) -> match
  cmux_tree_response "$dir" 3 window-1 "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" "$title" "cccccccc-2222-2222-2222-cccccccccccc"
  # 4: native tree confirms the default surface identity.
  cmux_tree_response "$dir" 4 window-1 "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" "$title" "cccccccc-2222-2222-2222-cccccccccccc"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb cccccccc-2222-2222-2222-cccccccccccc" ] \
    || fail "create_task should echo '<workspace_id> <surface_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''new-workspace'$'\x1f''--name'$'\x1f'"$title"$'\x1f''--cwd'$'\x1f''/tmp/proj' \
    "create_task did not call new-workspace with the right name/cwd"
  assert_contains "$(cat "$dir/log")" $'\x1f''--focus'$'\x1f''false' \
    "create_task did not pass --focus false"
  pass "fm_backend_cmux_create_task: creates a workspace and parses workspace_id/surface_id from list responses"
}

test_create_task_binds_in_other_window() {
  local dir fb title out n
  dir="$TMP_ROOT/create-bind-other-window"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-newtask)
  cmux_tree_response "$dir" 1 window-1 other independent other-surface
  for n in 3 4; do
    cmux_tree_response "$dir" "$n" window-1 other independent other-surface
    jq --arg t "$title" '
      .windows += [{id:"window-2",workspace_count:1,workspaces:[
        {id:"new-in-other-window",title:$t,description:null,
         panes:[{id:"new-pane",surface_count:1,surface_ids:["new-surface"],
           surfaces:[{id:"new-surface"}]}]}]}]
    ' "$dir/responses/$n.out" > "$dir/responses/$n.tmp"
    mv "$dir/responses/$n.tmp" "$dir/responses/$n.out"
  done
  fb=$(make_cmux_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-newtask /tmp/proj' "$ROOT")
  [ "$out" = 'new-in-other-window new-surface' ] || fail "create did not bind from app-wide post-create tree: $out"
  [ "$(grep -c $'\x1f''new-workspace' "$dir/log")" = 1 ] || fail 'create retried when result appeared in another window'
  pass 'cmux create: post-create identity and surface bind across windows without retry'
}

test_native_tree_rejects_nested_count_and_duplicate_surface() {
  local dir fb mode out rc
  for mode in surface-count duplicate-surface pane-mismatch multi-json; do
    dir="$TMP_ROOT/tree-$mode"; mkdir -p "$dir/responses"
    cmux_tree_response "$dir" 1 window-1 task task-title task-surface
    case "$mode" in
      surface-count) jq '.windows[0].workspaces[0].panes[0].surface_count = 2' "$dir/responses/1.out" > "$dir/responses/1.tmp" ;;
      duplicate-surface) jq '.windows[0].workspaces += [.windows[0].workspaces[0] | .id = "other" | .panes[0].id = "other-pane"] | .windows[0].workspace_count = 2' \
        "$dir/responses/1.out" > "$dir/responses/1.tmp" ;;
      pane-mismatch) jq '.windows[0].workspaces[0].panes[0].surfaces[0].pane_id = "wrong-pane"' \
        "$dir/responses/1.out" > "$dir/responses/1.tmp" ;;
      multi-json) cat "$dir/responses/1.out" "$dir/responses/1.out" > "$dir/responses/1.tmp" ;;
    esac
    mv "$dir/responses/1.tmp" "$dir/responses/1.out"
    fb=$(make_cmux_fakebin "$dir")
    out=$(PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
      bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_all_workspaces_json' "$ROOT" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$mode returned a successful inventory status"
    [ -z "$out" ] || fail "$mode produced a trusted inventory"
    [ "$(cat "$dir/responses/.count")" = 1 ] || fail "$mode retried a malformed native response"
  done
  pass 'cmux native tree: nested counts, ownership, duplicate surfaces, and multiple JSON documents are rejected'
}

# --- target_ready / capture ---------------------------------------------------

test_target_ready_fails_when_target_absent() {
  local dir fb status
  dir="$TMP_ROOT/ready-absent"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids -> no panes at all (surface absent)
  cmux_panes_empty_response "$dir" 1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should fail when list-panes reports the surface not found"
  pass "fm_backend_cmux_target_ready: fails when the workspace/surface is not found (list-panes structural check)"
}

test_target_ready_checks_expected_label() {
  local dir fb title
  dir="$TMP_ROOT/ready-label-ok"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-label)
  cmux_tree_response "$dir" 1 window-1 "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" "$title" "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb"
  # 2: list-panes --json --id-format uuids -> matching surface
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" fm-label' "$ROOT"
  expect_code 0 $? "target_ready should succeed when the workspace title matches the expected label"
  cmux_assert_call_order "$dir/log" $'\x1f''rpc'$'\x1f''system.tree' $'\x1f''list-panes' \
    "target_ready did not check the label before list-panes"
  pass "fm_backend_cmux_target_ready: verifies the workspace title against the expected label first"
}

test_target_ready_rejects_label_mismatch() {
  local dir fb status
  dir="$TMP_ROOT/ready-label-mismatch"; mkdir -p "$dir/responses"
  cmux_tree_response "$dir" 1 window-1 "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" "not-the-task" surface-1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_target_ready "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" fm-label' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should reject a workspace whose title does not match the expected label"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''list-panes' \
    "target_ready should not call list-panes after a label mismatch"
  pass "fm_backend_cmux_target_ready: rejects a workspace id reused under a different title"
}

test_capture_trims_locally() {
  local dir fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  # 2: read-screen --scrollback --lines 200 --json (actual fetch)
  cmux_read_screen_response "$dir" 2 $'line one\nline two\nline three\nline four'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 2' "$ROOT" )
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  cmux_assert_call_order "$dir/log" $'\x1f''list-panes'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    $'\x1f''--scrollback' "capture did not verify readiness before the actual read"
  pass "fm_backend_cmux_capture: fetches generously and trims to N lines locally"
}

test_capture_fails_when_read_screen_fails_empty() {
  local dir fb status
  dir="$TMP_ROOT/capture-read-fail"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  # 2: read-screen exits nonzero with no stdout
  printf '1' > "$dir/responses/2.exit"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 5' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when read-screen exits nonzero with no stdout"
  assert_contains "$(cat "$dir/log")" $'\x1f''read-screen' \
    "capture should attempt read-screen after readiness succeeds"
  pass "fm_backend_cmux_capture: propagates a read-screen failure even when stdout is empty"
}

test_capture_fails_when_target_not_ready() {
  local dir fb status
  dir="$TMP_ROOT/capture-not-ready"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids -> no matching surface
  cmux_panes_empty_response "$dir" 1
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_capture "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" 5' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the target is not ready"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''--scrollback' \
    "capture should not fetch after readiness fails"
  pass "fm_backend_cmux_capture: fails when the target surface is absent"
}

# --- send_key / send_literal --------------------------------------------------

test_send_key_normalizes_and_targets() {
  local dir fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''escape' \
    "send_key did not normalize Escape to escape and target the explicit workspace/surface"
  pass "fm_backend_cmux_send_key: normalizes the key (Escape -> escape) and targets the explicit workspace/surface"
}

test_send_key_recovers_stale_target_by_label() {
  local dir fb title
  dir="$TMP_ROOT/sendkey-stale-target"; mkdir -p "$dir/responses"
  title=$(cmux_expected_scoped_title fm-label)
  cmux_tree_response "$dir" 1 window-1 "cccccccc-2222-2222-2222-cccccccccccc" "$title" "dddddddd-3333-3333-3333-dddddddddddd"
  cmux_tree_response "$dir" 2 window-1 "cccccccc-2222-2222-2222-cccccccccccc" "$title" "dddddddd-3333-3333-3333-dddddddddddd"
  cmux_tree_response "$dir" 3 window-1 "cccccccc-2222-2222-2222-cccccccccccc" "$title" "dddddddd-3333-3333-3333-dddddddddddd"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_key "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" Enter fm-label' "$ROOT"
  expect_code 0 $? "send_key should recover a stale cmux target when the expected label is live"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''cccccccc-2222-2222-2222-cccccccccccc'$'\x1f''--surface'$'\x1f''dddddddd-3333-3333-3333-dddddddddddd'$'\x1f''enter' \
    "send_key did not use the refreshed cmux workspace/surface ids"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa' \
    "send_key should not target the stale cmux workspace id after label recovery"
  pass "fm_backend_cmux_send_key: recovers stale workspace/surface ids by expected label"
}

test_send_literal_uses_separator_for_option_shaped_text() {
  local dir fb
  dir="$TMP_ROOT/sendliteral"; mkdir -p "$dir/responses"
  # 1: list-panes --json --id-format uuids (target_ready)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_literal "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "--help"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''--help' \
    "send_literal did not call send with a -- separator before the literal payload"
  pass "fm_backend_cmux_send_literal: calls send with an explicit workspace/surface and a -- separator"
}

test_send_text_line_clears_partial_input_when_enter_fails() {
  local dir fb status log
  dir="$TMP_ROOT/sendline-enter-failure"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/4.exit"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  fb=$(make_cmux_fakebin "$dir")

  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "export TRACEPARENT=carrier"' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should report a failed Enter"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''export TRACEPARENT=carrier' \
    "send_text_line did not send the trace export before the simulated Enter failure"
  assert_contains "$log" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''ctrl-c' \
    "send_text_line did not clear the partial input after Enter failed"
  pass "fm_backend_cmux_send_text_line: clears partial input when Enter fails"
}

test_send_text_line_reports_unsafe_input_when_cleanup_fails() {
  local dir fb status log
  dir="$TMP_ROOT/sendline-cleanup-failure"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/4.exit"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  printf '1\n' > "$dir/responses/6.exit"
  fb=$(make_cmux_fakebin "$dir")

  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "export TRACEPARENT=carrier"' "$ROOT"
  status=$?
  expect_code 2 "$status" "send_text_line should distinguish uncleared input"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''ctrl-c' \
    "send_text_line did not attempt cleanup after Enter failed"
  pass "fm_backend_cmux_send_text_line: reports unsafe input when cleanup also fails"
}

# --- current_path: pwd-marker-probe (zellij-shape) ---------------------------

test_current_path_probes_with_marker() {
  local dir fb out
  # Verified real-cmux pitfall (docs/cmux-backend.md finding #2): the surface's
  # cwd is frozen at creation time (the top-level shell's cwd), never following
  # a foreground subshell (e.g. treehouse get) - so current_path actively
  # prints a marked cwd line and reads only that marker from the capture.
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"
  # 1: list-panes (current_path's own target_ready)
  # 2: list-panes (target_ready, called by send_text_line->send_literal)
  # 3: send (literal probe text)
  # 4: list-panes (target_ready, called by send_text_line->send_key)
  # 5: send-key enter
  # 6: list-panes (target_ready, called by capture)
  # 7: read-screen --scrollback --lines 200 --json (actual fetch)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 2 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 4 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 6 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 7 $'/tmp/proj\n❯ printf marker\n__FM_CMUX_CWD_BEGIN__\n/home/fixture/.treehouse/fake-worktree\n__FM_CMUX_CWD_END__\n/home/fixture/.treehouse/fake-worktree ❯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_current_path "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = "/home/fixture/.treehouse/fake-worktree" ] || fail "current_path should read only the marked cwd line, got '$out'"
  assert_contains "$(cat "$dir/log")" "__FM_CMUX_CWD_BEGIN__" "current_path did not send the cwd begin marker"
  assert_contains "$(cat "$dir/log")" "pwd;" "current_path did not send the pwd probe"
  assert_contains "$(cat "$dir/log")" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' \
    "current_path did not submit the cwd probe with Enter"
  pass "fm_backend_cmux_current_path: actively probes with marked begin/end lines (zellij-shape frozen cwd)"
}

# --- composer_state: structural border-row classification (adapted from herdr) ----

test_composer_state_bare_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via capture)
  # 2: read-screen --scrollback --lines <N> --json (composer capture)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_cmux_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_borderless_claude_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless Claude '❯' row bounded by horizontal rules should read empty, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude '❯' composer row reads empty"
}

test_composer_state_borderless_claude_prompt_outranks_stale_bordered_row() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-after-bordered"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'│ ❯ stale input │\n────────────────────────\n❯\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a current borderless Claude row should outrank stale bordered scrollback, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude row outranks stale bordered scrollback"
}

test_composer_state_borderless_claude_nbsp_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-nbsp"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯\302\240\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( LC_ALL=C PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless Claude '❯'+NBSP row bounded by horizontal rules should read empty under LC_ALL=C, got '$out'"
  pass "fm_backend_cmux_composer_state: a borderless Claude '❯'+NBSP composer row reads empty under LC_ALL=C"
}

test_composer_state_borderless_claude_text_is_unknown_plain() {
  # Capability degradation (the consolidated classifier's styled=0 rule): on
  # cmux's plain-text capture, text after a bare agent glyph is unreadable -
  # it may be the harness's own idle suggestion (claude's rotating dim hint,
  # codex's "Use /skills ..."), which a plain read cannot tell from typed
  # input. The verdict is `unknown` (defer, loud refusal at fm-send), never a
  # false `pending` that would misreport an idle pane as holding unsent text.
  # The same bytes on a styled backend (tmux/herdr/zellij) classify pending
  # when bright and empty when ghost - pinned in tests/fm-composer-lib.test.sh.
  local dir fb out
  dir="$TMP_ROOT/composer-borderless-claude-text"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'────────────────────────\n❯ retain this message\n────────────────────────\nHaiku 4.5'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "plain-capture text after a bare glyph must degrade to unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: plain-capture text after a bare glyph degrades to unknown (never false pending)"
}

test_composer_state_ghost_placeholder_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ──────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = empty ] || fail "the known ghost placeholder 'Type a message...' should read as empty, got '$out'"
  pass "fm_backend_cmux_composer_state: the ghost placeholder text reads empty, not pending"
}

test_composer_state_real_text_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_cmux_composer_state: real composer text reads pending"
}

# The popup-placeholder/second-Enter regression class (2026-07-03 herdr
# incident, docs/herdr-backend.md): a slash command's first Enter can close a
# completion popup and EXPAND the composer into an argument-hint placeholder
# rather than submitting. A raw content-diff check would misread the popup
# vanishing as "submitted"; the structural composer-row read must still call
# this pending so the caller retries a genuine second Enter.
test_composer_state_popup_placeholder_fill_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-popup-placeholder"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_cmux_composer_state: a slash-command popup's argument-hint placeholder still reads pending (the incident fix)"
}

test_composer_state_unknown_on_capture_failure() {
  local dir fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"
  printf '1\n' > "$dir/responses/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable surface should read as unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: reports unknown when the surface cannot be captured"
}

test_composer_state_unknown_when_no_composer_row_found() {
  local dir fb out
  dir="$TMP_ROOT/composer-no-row"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 2 'plain-shell-prompt$ '
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_composer_state "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111"' "$ROOT" )
  [ "$out" = unknown ] || fail "a capture with no recognizable composer row should read as unknown, got '$out'"
  pass "fm_backend_cmux_composer_state: reports unknown when no border-delimited composer row is found"
}

# --- send_text_submit: structural composer-row verify-and-retry --------------

test_send_text_submit_detects_landed_send() {
  local dir fb out
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via send_literal)
  # 2: send (literal text)
  # 3: list-panes (target_ready via send_key Enter)
  # 4: send-key enter
  # 5: list-panes (target_ready via composer_state's capture)
  # 6: read-screen --scrollback --lines N --json -> composer reads empty (submitted)
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the composer row reads empty, got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''hello captain' \
    "send_text_submit did not type the literal text first"
  enter_count=$(grep -c $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' "$dir/log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message with no popup, sent $enter_count Enter(s)"
  pass "fm_backend_cmux_send_text_submit: reports 'empty' once the composer row reads empty after one Enter"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯\n\n  Enter:send'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with no visible change, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'pending' when the composer never clears after retried Enters (swallowed)"
}

# The regression test for the popup-placeholder/second-Enter class (mirrors
# herdr's 2026-07-03 incident test): Enter #1 closes the popup and fills an
# argument-hint placeholder (still pending); Enter #2 actually submits. The
# adapter must retry past the first Enter instead of declaring victory on a
# raw content change, and must actually issue the second Enter.
test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local dir fb out
  dir="$TMP_ROOT/submit-popup-autocomplete"; mkdir -p "$dir/responses"
  # 1: list-panes (target_ready via send_literal)
  # 2: send "/compact"
  # 3: list-panes (target_ready via send_key Enter #1)
  # 4: send-key enter (#1) - closes the popup, fills the placeholder
  # 5: list-panes (target_ready via composer_state capture)
  # 6: composer still reads real (pending) text
  cmux_panes_response "$dir" 1 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 3 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 5 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 6 $'  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions   │\n  ╰──────────────── Composer ────────────╯\n\n  Enter:send'
  # 7: list-panes (target_ready via send_key Enter #2)
  # 8: send-key enter (#2) - actually submits
  # 9: list-panes (target_ready via composer_state capture)
  # 10: composer now reads empty
  cmux_panes_response "$dir" 7 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_panes_response "$dir" 9 "bbbbbbbb-1111-1111-1111-111111111111"
  cmux_read_screen_response "$dir" 10 $'  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ──────╯'
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "/compact" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  enter_count=$(grep -c $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''enter' "$dir/log")
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should have sent exactly 2 Enters (popup-close, then real submit), sent $enter_count"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''send'$'\x1f''--workspace'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''--surface'$'\x1f''bbbbbbbb-1111-1111-1111-111111111111'$'\x1f''--'$'\x1f''/compact compaction instructions' \
    "send_text_submit should never retype - only retry Enter"
  pass "fm_backend_cmux_send_text_submit: retries past a popup-placeholder-fill Enter and lands the real second Enter (the incident fix)"
}

test_send_text_submit_send_failed_when_target_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-target"; mkdir -p "$dir/responses"
  printf '1\n' > "$dir/responses/1.exit"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:bbbbbbbb-1111-1111-1111-111111111111" "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the target is absent, got '$out'"
  pass "fm_backend_cmux_send_text_submit: reports 'send-failed' when the target workspace/surface is absent"
}

# --- window_of_workspace: which window holds a workspace, and its count ------

test_window_of_workspace_finds_window_and_count() {
  local dir fb out
  dir="$TMP_ROOT/win-of-ws"; mkdir -p "$dir/responses"
  cmux_tree_response "$dir" 1 "e1111111-0000-0000-0000-e1111111eeee" "ffffffff-0000-0000-0000-ffffffffffff" other sf-other
  jq --arg win "e2222222-0000-0000-0000-e2222222eeee" '
    .windows += [{id:$win,workspace_count:1,workspaces:[{id:"aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa",title:"the-task",description:null,panes:[{id:"pane-target",surface_count:1,surface_ids:["sf-target"],surfaces:[{id:"sf-target"}]}]}]}]
  ' "$dir/responses/1.out" > "$dir/responses/1.tmp" && mv "$dir/responses/1.tmp" "$dir/responses/1.out"
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_window_of_workspace "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa"' "$ROOT" )
  [ "$out" = "e2222222-0000-0000-0000-e2222222eeee 1" ] \
    || fail "window_of_workspace should echo the owning window and its matched-list count, got '$out'"
  assert_grep $'\x1f''rpc'$'\x1f''system.tree' "$dir/log" "window_of_workspace did not use native tree"
  pass "fm_backend_cmux_window_of_workspace: resolves the owning window from one native tree"
}

test_window_of_workspace_empty_when_not_found() {
  local dir fb out
  dir="$TMP_ROOT/win-of-ws-none"; mkdir -p "$dir/responses"
  cmux_tree_response "$dir" 1 "e1111111-0000-0000-0000-e1111111eeee" "ffffffff-0000-0000-0000-ffffffffffff" other sf-other
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_window_of_workspace "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa"' "$ROOT" )
  [ -z "$out" ] || fail "window_of_workspace should echo nothing when the workspace is not found, got '$out'"
  pass "fm_backend_cmux_window_of_workspace: echoes nothing when no window holds the workspace"
}

# --- kill: semantic close refusal and confirmed app-wide absence -------------

make_cmux_close_case() {  # <name> <mode>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/fakebin" "$dir/home/state" "$dir/home/config" "$dir/home/data"
  printf '%s\n' "$2" > "$dir/mode"
  cmux_expected_scoped_title fm-close-task > "$dir/title"
  printf '%s\n' aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa > "$dir/wsid"
  cat > "$dir/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_CMUX_CLOSE_DIR:?}
mode=$(cat "$d/mode")
ws=$(cat "$d/wsid")
sf=bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb
win=eeeeeeee-0000-0000-0000-eeeeeeeeeeee
printf '%s\n' "$*" >> "$d/log"
case "$1" in
  version)
    [ "$mode" = confirm-unsupported-version ] && printf 'cmux 0.64.0 (1) [older]\n' \
      || printf 'cmux 0.65.2 (113) [12023d89f]\n'
    ;;
  rpc)
    [ "${2:-}" = system.tree ] || exit 2
    reads=$(cat "$d/rpc-reads" 2>/dev/null || printf 0)
    reads=$((reads+1)); printf '%s' "$reads" > "$d/rpc-reads"
    if [ "$mode" = delayed-close ] && [ -f "$d/attempted" ]; then
      close_reads=$(cat "$d/close-reads" 2>/dev/null || printf 0)
      close_reads=$((close_reads+1)); printf '%s' "$close_reads" > "$d/close-reads"
      [ "$close_reads" -ge 2 ] && touch "$d/gone"
    fi
    case "$mode" in
      inventory-error) exit 1 ;;
      post-error) [ -f "$d/attempted" ] && exit 1 ;;
      pre-read-error) [ ! -f "$d/created" ] && exit 1 ;;
      bad-schema) printf '{}'; exit 0 ;;
      pre-read-malformed) [ ! -f "$d/created" ] && { printf '{}'; exit 0; } ;;
      empty-windows) printf '{"windows":[]}'; exit 0 ;;
      empty-workspaces) printf '{"windows":[{"id":"%s","workspace_count":0,"workspaces":[]}]}' "$win"; exit 0 ;;
      post-empty) [ -f "$d/attempted" ] && { printf '{"windows":[{"id":"%s","workspace_count":0,"workspaces":[]}]}' "$win"; exit 0; } ;;
      force-empty) [ -f "$d/forced" ] && { printf '{"windows":[{"id":"%s","workspace_count":0,"workspaces":[]}]}' "$win"; exit 0; } ;;
      id-only) printf '{"windows":[{"id":"%s","workspace_count":1,"workspaces":[{"id":"other"}]}]}' "$win"; exit 0 ;;
      no-native) printf 'method_not_found: system.tree' >&2; exit 1 ;;
    esac
    delayed=0
    case "$mode" in
      launch-*)
        reads=$(cat "$d/reads" 2>/dev/null || printf 0)
        if [ ! -f "$d/created" ]; then delayed=1
        else
          reads=$((reads+1)); printf '%s' "$reads" > "$d/reads"
          if [ "$mode" = launch-timeout ] || [ "$reads" -lt 3 ]; then delayed=1; fi
        fi
        ;;
    esac
    title=$(cat "$d/title")
    target=1; other=1; duplicate=0
    if [ -f "$d/gone" ] || [ "$delayed" = 1 ]; then target=0; fi
    if [ -f "$d/last" ] && [ ! -f "$d/sibling" ]; then other=0; fi
    if [ "$target" = 0 ]; then other=1; fi
    if [ "$mode" = duplicate ] && [ ! -f "$d/gone" ]; then duplicate=1; fi
    if { [ "$mode" = duplicate ] || [ "$mode" = post-duplicate ]; } && [ -f "$d/gone" ]; then duplicate=1; fi
    if [ "$mode" = change-before-close ] && [ "$reads" -ge 2 ]; then extra=1
    elif [ -f "$d/extra-surface" ]; then extra=1
    else extra=0
    fi
    if [ "$mode" = launch-surface-timeout ] && [ "$target" = 1 ]; then
      jq -n --arg win "$win" --arg ws "$ws" --arg title "$title" \
        '{windows:[{id:$win,workspace_count:1,workspaces:[{id:$ws,title:$title,panes:[]}]}]}'
      exit 0
    fi
    jq -n --arg win "$win" --arg ws "$ws" --arg sf "$sf" --arg title "$title" \
      --argjson target "$target" --argjson other "$other" --argjson duplicate "$duplicate" \
      --argjson extra "$extra" --arg mode "$mode" '
      def node($id;$title;$sf;$extra):
        {id:$id,title:$title,description:null,
         panes:[{id:("pane-"+$id),surface_count:(1+$extra),
           surface_ids:([$sf]+(if $extra == 1 then ["unrelated-surface"] else [] end)),
           surfaces:([{id:$sf}]+(if $extra == 1 then [{id:"unrelated-surface"}] else [] end))}]};
      ([if $target == 1 then node($ws;$title;$sf;$extra) else empty end,
        if $other == 1 then node("other";"independent";"other-surface";0) else empty end,
        if $duplicate == 1 then node("duplicate";$title;"duplicate-surface";0) else empty end]) as $workspaces
      | {windows:[{id:$win,workspace_count:(($workspaces|length) + (if $mode == "count-mismatch" or $mode == "duplicate-id" then 1 else 0 end)),
          workspaces:(if $mode == "duplicate-id" then $workspaces + [$workspaces[0]] else $workspaces end)}]}'
    ;;
  list-panes)
    if [ "$mode" = launch-surface-timeout ]; then
      printf '{"panes":[]}'
    elif [ -f "$d/extra-surface" ]; then
      printf '{"panes":[{"surface_ids":["%s","unrelated"]}]}' "$sf"
    else
      printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$sf" "$sf"
    fi
    ;;
  new-workspace)
    case "$mode" in
      launch-*) touch "$d/created"; printf 'OK workspace:1'; [ "$mode" != launch-error ] || exit 1 ;;
      pre-read-*) touch "$d/created" ;;
      *) [ "$mode" = sibling-error ] || touch "$d/sibling" ;;
    esac
    ;;
  close-workspace)
    if [ "${2:-}" = --help ]; then
      { [ "$mode" = confirm-no-flag ] || [ "$mode" = confirm-no-capability ]; } && printf 'Usage: cmux close-workspace --workspace <id>' \
        || printf 'Usage: cmux close-workspace --workspace <id> [--force]'
      exit 0
    fi
    case "$*" in *"--workspace $ws"*) : ;; *) exit 99 ;; esac
    touch "$d/attempted"
    case "$mode" in
      error) exit 1 ;;
      noop|post-error) printf OK ;;
      refuse|confirm-unsupported-version) printf 'confirmation_required: Workspace has a running process; retry with --force' ;;
      confirm-no-capability) printf 'confirmation_required' ;;
      confirm-no-flag)
        case "$*" in
          *--force*) touch "$d/gone" "$d/forced"; printf OK ;;
          *) printf 'confirmation_required: Workspace has a running process; retry with --force' ;;
        esac
        ;;
      confirm|force-empty)
        case "$*" in
          *--force*) touch "$d/gone" "$d/forced"; printf OK ;;
          *) printf 'confirmation_required: Workspace has a running process; retry with --force' ;;
        esac
        ;;
      delayed-close) printf OK ;;
      *) touch "$d/gone"; printf OK ;;
    esac
    ;;
esac
SH
  chmod +x "$dir/fakebin/cmux"
  printf '%s' "$dir"
}

run_cmux_close_case() {  # <case> [expected-label]
  FM_CMUX_CLOSE_DIR="$1" FM_HOME="$1/home" FM_ROOT="$ROOT" FM_CMUX_LAYOUT=off \
    FM_CMUX_CLOSE_WAIT_TRIES="${FM_CMUX_CLOSE_WAIT_TRIES:-2}" FM_CMUX_CLOSE_WAIT_SLEEP=0 \
    PATH="$1/fakebin:$PATH" bash -c '. "$1"; fm_backend_cmux_kill "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" "" "$2"' \
    _ "${FM_TEST_CMUX_CLOSE_ADAPTER:-$ROOT/bin/backends/cmux.sh}" "${2:-}"
}

test_create_waits_without_recreating() {
  local dir grouped mode rc out
  for grouped in no yes; do
    for mode in launch-delay launch-timeout launch-surface-timeout launch-error; do
      dir=$(make_cmux_close_case "create-$grouped-$mode" "$mode")
      out=$(FM_CMUX_CLOSE_DIR="$dir" FM_HOME="$dir/home" FM_ROOT="$ROOT" FM_CMUX_LAYOUT=off \
        PATH="$dir/fakebin:$PATH" bash -c '
          . "$1"
          sleep() { :; }
          if [ "$2" = yes ]; then
            fm_cmux_layout_enabled() { return 0; }
            fm_cmux_layout_ensure() { printf "group:1\twindow:1"; }
          fi
          fm_backend_cmux_create_task fm-close-task /tmp
        ' _ "${FM_TEST_CMUX_CREATE_ADAPTER:-$ROOT/bin/backends/cmux.sh}" "$grouped" 2>"$dir/err")
      rc=$?
      if [ "$mode" = launch-delay ]; then
        [ "$rc" = 0 ] || fail "delayed $grouped create failed: $(cat "$dir/err")"
        assert_equals 'aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb' "$out" 'delayed readiness returned wrong endpoint'
      else
        [ "$rc" != 0 ] || fail "$mode must not announce a ready task"
      fi
      assert_equals 1 "$(grep -c '^new-workspace ' "$dir/log")" 'ambiguous creation must never create a second workspace'
    done
  done
  pass "fm_backend_cmux_create_task: plain and grouped delayed readiness succeeds without duplicate creates, and ambiguous failure preserves the first attempt"
}

test_create_refuses_unproven_duplicate_check() {
  local dir grouped mode
  for grouped in no yes; do
    for mode in pre-read-error pre-read-malformed; do
      dir=$(make_cmux_close_case "create-$grouped-$mode" "$mode")
      FM_CMUX_CLOSE_DIR="$dir" FM_HOME="$dir/home" FM_ROOT="$ROOT" FM_CMUX_LAYOUT=off \
        PATH="$dir/fakebin:$PATH" bash -c '
          . "$1"
          if [ "$2" = yes ]; then
            fm_cmux_layout_enabled() { return 0; }
            fm_cmux_layout_ensure() { printf "group:1\twindow:1"; }
          fi
          fm_backend_cmux_create_task fm-close-task /tmp
        ' _ "$ROOT/bin/backends/cmux.sh" "$grouped" > "$dir/out" 2> "$dir/err" \
        && fail "$grouped $mode accepted an unproven duplicate check"
      assert_no_grep new-workspace "$dir/log" "$grouped $mode attempted to create a duplicate"
    done
  done
  pass "cmux create: plain and grouped paths refuse unreadable or malformed pre-create inventory"
}

test_liveness_refuses_incomplete_inventory() {
  local dir mode state
  for mode in empty-workspaces id-only count-mismatch duplicate-id no-native; do
    dir=$(make_cmux_close_case "liveness-$mode" "$mode")
    state=$(FM_CMUX_CLOSE_DIR="$dir" FM_HOME="$dir/home" FM_ROOT="$ROOT" FM_CMUX_LAYOUT=off \
      PATH="$dir/fakebin:$PATH" bash -c '
        . "$1"
        fm_backend_cmux_ping_state() { printf ok; }
        fm_backend_cmux_agent_state "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb"
      ' _ "$ROOT/bin/backends/cmux.sh")
    assert_equals unreadable "$state" "$mode must not license recovery"
  done
  pass "cmux liveness: incomplete native inventory cannot report a task missing"
}

test_kill_closes_workspace_directly_when_not_last() {
  local dir
  dir=$(make_cmux_close_case kill-direct normal)
  run_cmux_close_case "$dir" || fail "ordinary verified close failed"
  assert_present "$dir/gone" "close did not remove its task workspace"
  assert_no_grep new-workspace "$dir/log" "non-last task should not create a sibling"
  pass "fm_backend_cmux_kill: ordinary close proves absence and preserves independent workspace"
}

test_kill_adds_sibling_when_last_in_window() {
  local dir
  dir=$(make_cmux_close_case kill-last normal)
  touch "$dir/last"
  run_cmux_close_case "$dir" || fail "last-workspace close failed"
  assert_present "$dir/sibling" "last-workspace close did not create its sibling"
  assert_present "$dir/gone" "last workspace survived its close"
  dir=$(make_cmux_close_case kill-last-refused sibling-error)
  touch "$dir/last"
  run_cmux_close_case "$dir" && fail "unconfirmed sibling creation must refuse"
  assert_absent "$dir/attempted" "close ran without a confirmed sibling"
  pass "fm_backend_cmux_kill: last-workspace close requires a confirmed sibling"
}

test_kill_confirmation_and_refusal() {
  local dir mode
  for mode in refuse noop error post-error bad-schema inventory-error empty-windows empty-workspaces post-empty force-empty id-only duplicate post-duplicate count-mismatch duplicate-id no-native change-before-close; do
    dir=$(make_cmux_close_case "kill-$mode" "$mode")
    run_cmux_close_case "$dir" fm-close-task && fail "$mode reported a false successful close"
    case "$mode" in
      post-empty|force-empty|post-duplicate) assert_present "$dir/gone" "$mode fixture did not close before its unproven read" ;;
      *) assert_absent "$dir/gone" "$mode unexpectedly removed the workspace" ;;
    esac
  done
  dir=$(make_cmux_close_case kill-confirm confirm)
  run_cmux_close_case "$dir" fm-close-task || fail "owned single-surface task did not close after confirmation"
  assert_grep --force "$dir/log" "confirmation did not retry the exact task close"
  assert_present "$dir/gone" "confirmed close left its workspace"
  pass "fm_backend_cmux_kill: zero-exit semantic refusal, no-op, and unproven reads never report success"
}

test_kill_waits_for_native_close_visibility() {
  local dir
  dir=$(make_cmux_close_case kill-delayed-close delayed-close)
  FM_CMUX_CLOSE_WAIT_TRIES=4 run_cmux_close_case "$dir" fm-close-task \
    || fail 'delayed native absence should confirm the one close'
  assert_equals 1 "$(grep -c '^close-workspace ' "$dir/log")" 'delayed visibility must not cause a second close'
  assert_present "$dir/gone" 'delayed close never became absent'
  pass 'fm_backend_cmux_kill: bounded native polling confirms delayed absence without a second close'
}

test_kill_accepts_server_advertised_force() {
  local dir
  dir=$(make_cmux_close_case kill-no-confirm-flag confirm-no-flag)
  run_cmux_close_case "$dir" fm-close-task || fail 'server-advertised force should close the exact owned task'
  assert_grep --force "$dir/log" 'server-advertised flag was not used'
  assert_present "$dir/gone" 'server-advertised confirmation did not close the task'
  pass 'fm_backend_cmux_kill: a server-advertised force works when installed help omits the flag'
}

test_kill_refuses_unknown_confirmation_capability() {
  local dir
  dir=$(make_cmux_close_case kill-no-capability confirm-no-capability)
  run_cmux_close_case "$dir" fm-close-task && fail 'unknown confirmation capability must refuse'
  assert_equals 1 "$(grep -c '^close-workspace --workspace ' "$dir/log")" 'unknown capability must mean no retry'
  assert_absent "$dir/gone" 'unknown capability removed the task'
  dir=$(make_cmux_close_case kill-unsupported-version confirm-unsupported-version)
  run_cmux_close_case "$dir" fm-close-task && fail 'unverified client build must refuse confirmation'
  assert_equals 1 "$(grep -c '^close-workspace --workspace ' "$dir/log")" 'unverified build must mean no retry'
  assert_absent "$dir/gone" 'unverified client removed the task'
  pass 'fm_backend_cmux_kill: unknown server capability or unpinned client retains the endpoint'
}

test_kill_never_forces_unbound_or_shared_workspace() {
  local dir
  dir=$(make_cmux_close_case kill-unbound confirm)
  run_cmux_close_case "$dir" && fail "unbound task confirmation should refuse"
  assert_no_grep --force "$dir/log" "unbound close attempted force"
  dir=$(make_cmux_close_case kill-extra confirm)
  touch "$dir/extra-surface"
  run_cmux_close_case "$dir" fm-close-task && fail "extra surface confirmation should refuse"
  assert_no_grep --force "$dir/log" "shared workspace close attempted force"
  dir=$(make_cmux_close_case kill-extra-normal normal)
  touch "$dir/extra-surface"
  run_cmux_close_case "$dir" fm-close-task && fail "ordinary close of extra surface should refuse"
  assert_absent "$dir/attempted" "ordinary close reached a shared workspace"
  dir=$(make_cmux_close_case kill-identity confirm)
  printf unrelated > "$dir/title"
  run_cmux_close_case "$dir" fm-close-task && fail "changed workspace identity should refuse"
  assert_absent "$dir/attempted" "mismatched task close reached the endpoint"
  pass "fm_backend_cmux_kill: confirmation never forces an unbound, shared, or mismatched endpoint"
}

test_kill_recovers_stale_target_by_label() {
  local dir
  dir=$(make_cmux_close_case kill-recovered confirm)
  printf '%s\n' cccccccc-2222-2222-2222-cccccccccccc > "$dir/wsid"
  run_cmux_close_case "$dir" fm-close-task || fail "scoped label recovery failed"
  assert_grep 'close-workspace --workspace cccccccc-2222-2222-2222-cccccccccccc' "$dir/log" "close did not use recovered identity"
  assert_no_grep 'close-workspace --workspace aaaaaaaa-' "$dir/log" "close used the stale workspace"
  dir=$(make_cmux_close_case kill-already-gone normal)
  touch "$dir/gone"
  run_cmux_close_case "$dir" fm-close-task || fail "proven already-gone task should succeed"
  assert_absent "$dir/attempted" "already-gone task attempted a close"
  pass "fm_backend_cmux_kill: recovers by scoped label and accepts proven absence"
}

test_teardown_cmux_retains_unproven_endpoint() {
  local dir mode rc
  command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not installed'; return; }
  for mode in refuse noop post-error empty-windows empty-workspaces post-empty force-empty id-only duplicate post-duplicate count-mismatch duplicate-id no-native change-before-close confirm; do
    dir=$(make_cmux_close_case "teardown-$mode" "$mode")
    mkdir -p "$dir/project"
    git init -q "$dir/project"
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
    cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
    ( cd "$dir/home" && tasks-axi add close-task 'close fixture' --kind ship --file data/backlog.md >/dev/null && tasks-axi start close-task --file data/backlog.md >/dev/null ) || fail "backlog fixture failed"
    fm_write_meta "$dir/home/state/close-task.meta" \
      'backend=cmux' 'endpoint_task_id=close-task' 'spawn_gen=s1.2.3' \
      'window=aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb' \
      'cmux_workspace_id=aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa' 'cmux_surface_id=bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb' \
      "worktree=$dir/project" "project=$dir/project" 'kind=ship' 'mode=local-only' 'workspace_isolation=shared-checkout'
    cp "$dir/home/state/close-task.meta" "$dir/meta-before"
    FM_CMUX_CLOSE_DIR="$dir" FM_CMUX_LAYOUT=off FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
      PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" close-task --force > "$dir/out" 2> "$dir/err"
    rc=$?
    if [ "$mode" = confirm ]; then
      [ "$rc" = 0 ] || fail "confirmed teardown failed: $(cat "$dir/err")"
      assert_absent "$dir/home/state/close-task.meta" "verified close retained task metadata"
      assert_present "$dir/gone" "successful teardown did not close the task"
      assert_equals 'done' "$(tasks-axi show close-task --file "$dir/home/data/backlog.md" | sed -n 's/^  state: *//p' | head -1)" "successful teardown did not close its backlog row"
    else
      [ "$rc" != 0 ] || fail "teardown falsely succeeded for $mode: $(cat "$dir/out")"
      assert_present "$dir/home/state/close-task.meta" "unproven close discarded metadata even with force"
      assert_absent "$dir/home/state/close-task.backlog-close" "startup replay could erase an unproven endpoint"
      cmp -s "$dir/meta-before" "$dir/home/state/close-task.meta" || fail "refused teardown changed endpoint metadata"
      assert_equals in_flight "$(tasks-axi show close-task --file "$dir/home/data/backlog.md" | sed -n 's/^  state: *//p' | head -1)" "refused teardown changed its backlog state"
      assert_no_grep 'teardown close-task complete' "$dir/out" "false completion announcement"
      if [ "$mode" = empty-windows ] || [ "$mode" = empty-workspaces ] || [ "$mode" = id-only ] || [ "$mode" = duplicate ] || [ "$mode" = count-mismatch ] || [ "$mode" = duplicate-id ] || [ "$mode" = no-native ] || [ "$mode" = change-before-close ]; then
        assert_no_grep close-workspace "$dir/log" "unproven inventory must stop before close"
      else
        assert_grep close-workspace "$dir/log" "fixture never reached the failing close"
      fi
    fi
  done
  pass "fm-teardown: cmux refusal retains metadata across startup replay; confirmed task close retires records"
}

# --- list_live: label-based orphan discovery ---------------------------------

test_list_live_filters_by_title_prefix() {
  local dir fb out title other_title other_root
  dir="$TMP_ROOT/list-live"; mkdir -p "$dir/responses"
  other_root="$dir/other-root"; mkdir -p "$other_root"
  title=$(cmux_expected_scoped_title fm-task1)
  other_title=$(cmux_expected_scoped_title fm-task2 "$ROOT" "$other_root")
  cmux_tree_response "$dir" 1 window-1 \
    "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" "$title" "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" \
    "dddddddd-8888-8888-8888-dddddddddddd" "$other_title" other-surface \
    "cccccccc-9999-9999-9999-cccccccccccc" zsh shell-surface
  fb=$(make_cmux_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_list_live' "$ROOT" )
  [ "$out" = $'aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa:bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb\tfm-task1' ] \
    || fail "list_live should list only the in-home task workspace with its plain label and surface id, got '$out'"
  pass "fm_backend_cmux_list_live: lists only this home's scoped task workspaces using plain fm-<id> labels"
}

# --- fm-spawn.sh: --secondmate refuses backend=cmux --------------------------

test_secondmate_spawn_refuses_cmux_backend() {
  local dir state data config projects out status
  dir="$TMP_ROOT/secondmate-refuse"; state="$dir/state"; data="$dir/data"; config="$dir/config"; projects="$dir/projects"
  mkdir -p "$state" "$data" "$config" "$projects"
  out=$( FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-spawn.sh" sm-cmux-test --secondmate --backend cmux 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a --secondmate spawn with --backend cmux"
  assert_contains "$out" "does not support --secondmate" "fm-spawn.sh did not report the cmux secondmate refusal"
  pass "fm-spawn.sh: refuses backend=cmux for --secondmate spawns (mirrors Orca's refusal; no secondmate launch design exists yet)"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_cmux
test_password_reads_from_config_file
test_password_preserves_config_file_whitespace
test_password_respects_config_override
test_password_empty_when_config_absent
test_cli_exports_password_only_when_configured
test_parse_target
test_normalize_key
test_scoped_title_uses_primary_home_label
test_scoped_title_uses_secondmate_home_label
test_scoped_title_changes_with_root_path
test_dispatch_routes_cmux_backend
test_dispatch_busy_state_unknown_for_cmux
test_dispatch_composer_state_routes_cmux
test_ping_state_ok
test_ping_state_denied
test_ping_state_unauth
test_ping_state_invalid_password
test_ping_state_down
test_ensure_running_returns_immediately_when_already_ok
test_ensure_running_fails_fast_on_denied_without_launching
test_ensure_running_fails_fast_on_unauth_without_launching
test_create_task_refuses_duplicate_label
test_create_task_refuses_other_window_duplicate
test_create_task_refuses_native_failure_and_count_mismatch
test_create_task_creates_and_parses_ids
test_create_task_binds_in_other_window
test_native_tree_rejects_nested_count_and_duplicate_surface
test_target_ready_fails_when_target_absent
test_target_ready_checks_expected_label
test_target_ready_rejects_label_mismatch
test_capture_trims_locally
test_capture_fails_when_read_screen_fails_empty
test_capture_fails_when_target_not_ready
test_send_key_normalizes_and_targets
test_send_key_recovers_stale_target_by_label
test_send_literal_uses_separator_for_option_shaped_text
test_send_text_line_clears_partial_input_when_enter_fails
test_send_text_line_reports_unsafe_input_when_cleanup_fails
test_current_path_probes_with_marker
test_composer_state_bare_prompt_is_empty
test_composer_state_borderless_claude_prompt_is_empty
test_composer_state_borderless_claude_prompt_outranks_stale_bordered_row
test_composer_state_borderless_claude_nbsp_prompt_is_empty
test_composer_state_borderless_claude_text_is_unknown_plain
test_composer_state_ghost_placeholder_is_empty
test_composer_state_real_text_is_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_unknown_on_capture_failure
test_composer_state_unknown_when_no_composer_row_found
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_text_submit_send_failed_when_target_absent
test_window_of_workspace_finds_window_and_count
test_window_of_workspace_empty_when_not_found
test_create_waits_without_recreating
test_create_refuses_unproven_duplicate_check
test_liveness_refuses_incomplete_inventory
test_kill_closes_workspace_directly_when_not_last
test_kill_confirmation_and_refusal
test_kill_waits_for_native_close_visibility
test_kill_accepts_server_advertised_force
test_kill_refuses_unknown_confirmation_capability
test_kill_adds_sibling_when_last_in_window
test_kill_never_forces_unbound_or_shared_workspace
test_kill_recovers_stale_target_by_label
test_teardown_cmux_retains_unproven_endpoint
test_list_live_filters_by_title_prefix
test_secondmate_spawn_refuses_cmux_backend
