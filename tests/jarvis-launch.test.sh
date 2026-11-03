#!/usr/bin/env bash
# tests/jarvis-launch.test.sh - bin/jarvis-launch with stub claude and codex
# CLIs: from an outer folder it keeps that folder as the working directory,
# starts the plugin manager agent with the home's hooks rewritten to
# JARVIS_HOME, and exports the home; inside the home it is plain `claude`.
# The live check (real Claude Code, outer CLAUDE.md and AGENTS.md) is in
# docs/install.md "Launch shortcut"; Codex is verified on a personal laptop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-launch-tests)
export JARVIS_HOME_POINTER="$TMP_ROOT/home-pointer"
LAUNCH="$ROOT/bin/jarvis-launch"

# A stub CLI that records its cwd, environment and arguments.
make_stub() {  # <dir> <name>
  mkdir -p "$1"
  cat > "$1/$2" <<STUB
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "\$(pwd -P)"
  printf 'JARVIS_HOME=%s\n' "\${JARVIS_HOME:-}"
  printf 'FM_HOME=%s\n' "\${FM_HOME:-}"
  printf 'arg=%s\n' "\$@"
} > "$1/$2.calls"
STUB
  chmod +x "$1/$2"
}

test_outer_folder_claude() {
  local bin="$TMP_ROOT/bin" outer="$TMP_ROOT/outer" calls settings
  make_stub "$bin" claude
  mkdir -p "$outer"
  (cd "$outer" && PATH="$bin:$PATH" FM_HOME="$TMP_ROOT/home-state" "$LAUNCH" --claude -- -p hello) || fail "launch must exec claude"
  calls=$(cat "$bin/claude.calls")
  printf '%s\n' "$calls" | grep -qx "cwd=$(cd "$outer" && pwd -P)" || fail "the outer folder must stay the working directory: $calls"
  printf '%s\n' "$calls" | grep -qx "JARVIS_HOME=$ROOT" || fail "JARVIS_HOME must point at the home: $calls"
  printf '%s\n' "$calls" | grep -qx "FM_HOME=$TMP_ROOT/home-state" || fail "an explicit FM_HOME must be kept: $calls"
  printf '%s\n' "$calls" | grep -qx 'arg=--agent' || fail "must pass --agent: $calls"
  printf '%s\n' "$calls" | grep -qx 'arg=jarvis-ai-george:jarvis-ai-george' || fail "must start the plugin manager agent: $calls"
  printf '%s\n' "$calls" | grep -qx 'arg=-p' || fail "extra arguments must pass through: $calls"
  settings=$(printf '%s\n' "$calls" | awk '/^arg=--settings$/ {getline; sub(/^arg=/, ""); print}')
  [ -f "$settings" ] || fail "--settings must name a generated file: $calls"
  grep -q 'CLAUDE_PROJECT_DIR' "$settings" && fail "no hook may still point at the project dir"
  grep -q 'JARVIS_HOME\\"/bin/hook fm-sessionstart-run.sh' "$settings" || fail "the session-start hook must run from the home, through bin/hook"
  grep -q 'JARVIS_HOME\\"/bin/hook jarvis-setup.sh detect' "$settings" || fail "the setup check must run from the home, through bin/hook"
  grep -q 'JARVIS_HOME\\"/bin/hook --notice' "$settings" || fail "the update notice must be carried"
  grep -q 'bin/hook jarvis-manager-write-guard.sh' "$settings" || fail "the write guard must be carried through bin/hook (plugin agents ignore agent hooks)"
  grep -q '"agent"' "$settings" && fail "the launch settings must not set the project agent"
  pass "jarvis-launch: an outer folder stays the cwd, the plugin manager starts, hooks run from the home"
}

test_inside_home_is_plain_claude() {
  local bin="$TMP_ROOT/bin2" calls
  make_stub "$bin" claude
  (cd "$ROOT" && PATH="$bin:$PATH" "$LAUNCH" --claude) || fail "launch in the home must exec claude"
  calls=$(cat "$bin/claude.calls")
  printf '%s\n' "$calls" | grep -q '^arg=--agent' && fail "inside the home the repo settings apply, no --agent: $calls"
  printf '%s\n' "$calls" | grep -qx "JARVIS_HOME=$ROOT" || fail "JARVIS_HOME must still be set: $calls"
  pass "jarvis-launch: inside the home it is plain claude, so the repo settings apply as before"
}

test_codex_first_prompt() {
  local bin="$TMP_ROOT/bin3" outer="$TMP_ROOT/outer3" calls
  make_stub "$bin" codex
  mkdir -p "$outer"
  (cd "$outer" && PATH="$bin:$PATH" "$LAUNCH" --codex) || fail "launch must exec codex"
  calls=$(cat "$bin/codex.calls")
  printf "%s\n" "$calls" | grep -qF "arg=Load \$role-jarvis first" || fail "codex must load role-jarvis first: $calls"
  printf '%s\n' "$calls" | grep -q "$ROOT/AGENTS.md" || fail "codex must be pointed at the home contract: $calls"
  pass "jarvis-launch: codex starts in the folder and loads role-jarvis and the home contract (stub only)"
}

test_outer_folder_claude
test_inside_home_is_plain_claude
test_codex_first_prompt
