#!/usr/bin/env bash
# jarvis-sidebar.sh - Claude Code (and Codex) hook: this session's state as cmux
# sidebar pills on its own workspace.
#
# Pills (keys, top to bottom):
#   jarvis_activity   Ready / Working: <ask> / Waiting: <ask> / Needs approval /
#                     Done: <last step> / Error: <last step>
#   jarvis_tool       the current tool ("Reading README.md", "Running tests"),
#                     its past form once it finished, "<tool> failed" on error
#   jarvis_subagents  "Subagents: 2 running" while subagents run
#   jarvis_pr         "PR #12 open" for the branch the session works on (gh)
#   jarvis_issue      "Issue #7" from the PR's closing issue or the branch name
#
# Design:
#   - Each hook records the DESIRED pill state (pill/<key>) and returns. A
#     writer reconciles desired against SENT (sent/<key>) under a per-surface
#     lock, re-running while a newer event arrived, so hooks that fire in
#     parallel converge on the latest state instead of replaying commands out
#     of order. A pill is marked sent only after cmux accepted it.
#   - The phase machine (start, prompt, tool, permission, stop, end) runs under
#     a short per-surface lock and checks its own preconditions, because hooks
#     for one surface have no order among themselves.
#   - Ownership: the first session on a surface owns it, identified by its
#     client process (pid plus start time). A different session id with a live
#     owner (a nested `claude -p`, a second client in a split pane) never drives
#     the tab; a `/clear` from the same client re-adopts; when the owner is gone
#     the next start or prompt takes over.
#   - Subagents are one file each, so parallel starts and stops never lose an
#     update, and subagent events never move a finished turn back to Working.
#   - PR and issue lookups run only in the writer, rate limited per branch.
#
# Contract: a no-op outside cmux (no CMUX_WORKSPACE_ID); never writes stdout
# (UserPromptSubmit stdout reaches the prompt); always exits 0; returns well
# inside the 3s Codex hook cap because cmux and gh only run in a detached writer
# whose every call is time-bounded. JARVIS_SIDEBAR=off turns it off;
# JARVIS_SIDEBAR_SYNC=1 runs the writer inline (tests).
# docs/cmux-backend.md "Sidebar" owns the operator view.
set -u
exec >/dev/null
[ -n "${JARVIS_SIDEBAR_DEBUG:-}" ] || exec 2>/dev/null

drain_exit() { [ -t 0 ] || cat >/dev/null 2>&1; exit 0; }
[ "${JARVIS_SIDEBAR:-on}" = off ] && drain_exit
WS=${JARVIS_SIDEBAR_WS:-${CMUX_WORKSPACE_ID:-}}
[ -n "$WS" ] || drain_exit
case "$WS" in .*|*[!A-Za-z0-9._:-]*) drain_exit ;; esac
[ "${#WS}" -le 80 ] || drain_exit
command -v jq >/dev/null 2>&1 || drain_exit
CMUX_BIN=${JARVIS_SIDEBAR_CMUX:-$(command -v cmux 2>/dev/null || true)}
[ -n "$CMUX_BIN" ] || CMUX_BIN=/Applications/cmux.app/Contents/Resources/bin/cmux
[ -x "$CMUX_BIN" ] || drain_exit
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac

US=$'\037'
ROOT=${JARVIS_SIDEBAR_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/jarvis-ai-george/sidebar}
case "$ROOT" in /?*) ;; *) drain_exit ;; esac
SD="$ROOT/$WS"
FRESH=0
if [ ! -d "$SD" ]; then
  (umask 077; mkdir -p "$SD/pill" "$SD/sent" "$SD/sub") 2>/dev/null || drain_exit
  FRESH=1
fi
[ -d "$SD" ] && [ ! -L "$SD" ] && [ -O "$SD" ] || drain_exit
mkdir -p "$SD/pill" "$SD/sent" "$SD/sub" 2>/dev/null

# ---- 1. The event, in one jq pass ------------------------------------------
EVENT=$(cat 2>/dev/null)
F=$(printf '%s' "$EVENT" | jq -r '
  def s: tostring | gsub("[\\n\\r\\t\u001f]"; " ");
  (try (.tool_input // {} | if type == "object" then . else {} end) catch {}) as $i |
  [ (.hook_event_name // ""), (.session_id // ""), (.tool_name // ""), (.cwd // ""),
    (.agent_id // ""), (.agent_type // ""),
    (try (.prompt // "" | tostring | .[0:400]) catch ""),
    (try (.last_assistant_message // "" | tostring | .[-200:]) catch ""),
    (try ($i.file_path // $i.path // $i.notebook_path // "" | tostring | .[0:300]) catch ""),
    (try (($i.command // $i.cmd // "") | if type == "array" then map(tostring) | join(" ") else tostring end | .[0:300]) catch ""),
    (try ($i.url // "" | tostring | .[0:300]) catch ""),
    (try ($i.subagent_type // $i.description // $i.skill // $i.name // "" | tostring | .[0:80]) catch ""),
    (try (if ((.tool_error? // .error? // null) != null)
            or (((.tool_response | type) == "object") and (.tool_response.success == false))
          then "bad" else "ok" end) catch "ok"),
    (.notification_type // ""), (try (.message // "" | tostring | .[0:200]) catch ""),
    (.source // .reason // "" | tostring | .[0:40])
  ] | map(s) | join("\u001f")' 2>/dev/null) || F=""
IFS="$US" read -r EV SID TOOL CWD AGENT_ID AGENT_TYPE PROMPT RESPONSE TI_PATH TI_CMD TI_URL TI_NAME TOOL_OK NTYPE NMSG SRC <<EOF
${F:-}
EOF
EV=${EV:-}; SID=${SID:-}; TOOL=${TOOL:-}; CWD=${CWD:-}; AGENT_ID=${AGENT_ID:-}
PROMPT=${PROMPT:-}; RESPONSE=${RESPONSE:-}; TI_PATH=${TI_PATH:-}; TI_CMD=${TI_CMD:-}
TI_URL=${TI_URL:-}; TI_NAME=${TI_NAME:-}; TOOL_OK=${TOOL_OK:-ok}; NTYPE=${NTYPE:-}; NMSG=${NMSG:-}; SRC=${SRC:-}
AGENT_TYPE=${AGENT_TYPE:-}
case "$EV" in
  SessionStart) EV=start ;;
  UserPromptSubmit) EV=prompt ;;
  PreToolUse) EV=pre ;;
  PostToolUse) EV=post ;;
  PostToolUseFailure) EV=post; TOOL_OK=bad ;;
  PermissionRequest) EV=permission ;;
  Notification)
    # Only a permission prompt asks the user for something; an idle reminder
    # after a finished turn does not.
    case "$NTYPE$NMSG" in
      *permission*|*Permission*) EV=permission ;;
      *) exit 0 ;;
    esac ;;
  Stop) EV=stop ;;
  SubagentStart) EV=sub_start ;;
  SubagentStop) EV=sub_stop ;;
  SessionEnd) EV=end ;;
  *) exit 0 ;;
esac
IS_SUB=0
[ -n "$AGENT_ID" ] && IS_SUB=1
case "$EV" in sub_start|sub_stop) IS_SUB=0 ;; esac

# ---- 2. State files and the lock -------------------------------------------
V=""
get() { V=""; [ -f "$SD/$1" ] && { IFS= read -r V < "$SD/$1" || true; }; }
put() {
  if printf '%s' "$2" > "$SD/$1.tmp.$$"; then mv -f "$SD/$1.tmp.$$" "$SD/$1"; else rm -f "$SD/$1.tmp.$$"; fi
}
MYPID=$$
# lock <dir> [spins]: mkdir lock holding our pid; a dead holder or one older
# than a minute is reclaimed. 0 when held.
lock() {
  local d=$1 spins=${2:-40} i=0 pid
  while [ "$i" -lt "$spins" ]; do
    i=$((i + 1))
    if mkdir "$d" 2>/dev/null; then printf '%s' "$MYPID" > "$d/pid" 2>/dev/null && return 0; fi
    pid=""; [ -f "$d/pid" ] && { IFS= read -r pid < "$d/pid" || true; }
    if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } \
       || [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$d" 2>/dev/null
      continue
    fi
    sleep 0.05
  done
  return 1
}
unlock() { local pid=""; [ -f "$1/pid" ] && { IFS= read -r pid < "$1/pid" || true; }; [ "$pid" = "$MYPID" ] && rm -rf "$1"; }

if lock "$SD/.phase.lock" 40; then trap 'unlock "$SD/.phase.lock"' EXIT; fi

# ---- 3. Ownership -----------------------------------------------------------
# The nearest ancestor that is the agent client (claude or codex).
client_pid() {
  if [ -n "${JARVIS_SIDEBAR_CLIENT_PID:-}" ]; then printf '%s' "$JARVIS_SIDEBAR_CLIENT_PID"; return 0; fi
  local p=$PPID l i bin
  for i in 1 2 3 4 5 6; do
    [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || return 1
    l=$(ps -o ppid=,command= -p "$p" 2>/dev/null) || return 1
    set -f
    # shellcheck disable=SC2086 # split the ps line into words on purpose
    set -- $l
    set +f
    bin=${2:-}; bin=${bin##*/}
    case "$bin" in
      claude|claude-code|codex) printf '%s' "$p"; return 0 ;;
      node) case "$l" in *claude-code*|*@anthropic-ai/claude*|*@openai/codex*) printf '%s' "$p"; return 0 ;; esac ;;
    esac
    p=${1:-}
  done
  return 1
}
proc_start() { ps -o lstart= -p "$1" 2>/dev/null; }
owner_alive() {
  local st=""
  get owner_pid
  [ -n "$V" ] || return 1
  kill -0 "$V" 2>/dev/null || return 1
  [ -f "$SD/owner_start" ] && { IFS= read -r st < "$SD/owner_start" || true; }
  [ -z "$st" ] || [ "$(proc_start "$V")" = "$st" ]
}
adopt() {
  local pid
  put session "$SID"
  pid=$(client_pid) || pid=""
  put owner_pid "$pid"
  if [ -n "$pid" ]; then put owner_start "$(proc_start "$pid")"; else rm -f "$SD/owner_start"; fi
}
get session; OWNER_SID=$V
if [ -z "$SID" ]; then
  exit 0
elif [ -z "$OWNER_SID" ]; then
  adopt
elif [ "$SID" != "$OWNER_SID" ]; then
  get owner_pid; op=$V
  case "$EV" in
    start|prompt)
      if [ -n "$op" ] && [ "$(client_pid)" = "$op" ]; then adopt      # /clear, /resume in the same client
      elif ! owner_alive; then adopt                                  # the owner is gone: take over
      else exit 0                                                     # a live other client: never drive it
      fi ;;
    *) exit 0 ;;
  esac
fi

# ---- 4. Desired pills -------------------------------------------------------
C_WORK='#3B82F6'; C_WAIT='#F59E0B'; C_DONE='#6B7280'; C_ERR='#EF4444'; C_TOOL='#8B5CF6'; C_REF='#10B981'
clean() { local v=${1//$US/ }; v=${v//[[:cntrl:]]/ }; printf '%s' "$v"; }
pill() {  # <key> <text> <icon> <color> <priority> [url]
  local v
  v="$(clean "$2")$US$3$US$4$US$5$US$(clean "${6:-}")"
  get "pill/$1"; [ "$V" = "$v" ] && return 0
  put "pill/$1" "$v"
}
unpill() { [ -s "$SD/pill/$1" ] || [ -s "$SD/sent/$1" ] || return 0; : > "$SD/pill/$1"; }

# ---- 5. Tool descriptions ---------------------------------------------------
D=""; IC=""
ing() { if [ "${PAST:-}" = 1 ]; then D=$2; else D=$1; fi; }
short() { local x=${1##*/}; x=${x//\"/}; printf '%s' "${x:0:28}"; }
describe_cmd() {
  local c=$1 re bin a2
  re='^[A-Z_][A-Z0-9_]*=[^ ]* +'
  while [[ $c =~ $re ]]; do c=${c#"${BASH_REMATCH[0]}"}; done
  re='^cd [^;&|]*(&&|;) *'
  [[ $c =~ $re ]] && c=${c#"${BASH_REMATCH[0]}"}
  set -f
  # shellcheck disable=SC2086 # split the command into words on purpose
  set -- $c
  set +f
  bin=${1:-}; bin=${bin##*/}; a2=${2:-}
  case "$c" in *'|'*|*'&&'*|*';'*) ing 'Running shell commands' 'Ran shell commands'; return ;; esac
  case "$bin" in
    '') ing 'Running a command' 'Ran a command' ;;
    git) case "$a2" in
           status|diff|log|show|branch) ing "Checking git $a2" "Checked git $a2" ;;
           commit) ing 'Committing' 'Committed' ;;
           push) ing 'Pushing' 'Pushed' ;;
           *) ing "Running git ${a2:-}" "Ran git ${a2:-}" ;;
         esac ;;
    gh) ing "Running gh ${a2:-}" "Ran gh ${a2:-}" ;;
    grep|rg|ag) ing 'Searching files' 'Searched files' ;;
    ls|find|tree) ing 'Listing files' 'Listed files' ;;
    cat|head|tail|less|sed) ing "Reading $(short "${!#}")" "Read $(short "${!#}")" ;;
    sleep) ing 'Waiting' 'Waited' ;;
    pytest|jest|mocha|vitest) ing 'Running tests' 'Ran tests' ;;
    npm|yarn|pnpm|cargo|go) case "$a2" in test) ing 'Running tests' 'Ran tests' ;; build) ing 'Building' 'Built' ;; *) ing "Running $bin ${a2:-}" "Ran $bin ${a2:-}" ;; esac ;;
    make) ing 'Building' 'Built' ;;
    curl|wget) ing 'Fetching a URL' 'Fetched a URL' ;;
    *) case "$c" in *test*) ing 'Running tests' 'Ran tests' ;; *) ing "Running $(short "$bin")" "Ran $(short "$bin")" ;; esac ;;
  esac
}
describe_tool() {  # sets D and IC
  local t=$TOOL host
  IC=bolt.fill
  case "$t" in
    Read) ing "Reading $(short "$TI_PATH")" "Read $(short "$TI_PATH")"; IC=doc.text ;;
    Write) ing "Writing $(short "$TI_PATH")" "Wrote $(short "$TI_PATH")"; IC=pencil ;;
    Edit|MultiEdit|NotebookEdit|apply_patch) ing "Editing $(short "$TI_PATH")" "Edited $(short "$TI_PATH")"; IC=pencil ;;
    Bash|shell|exec_command|local_shell) describe_cmd "$TI_CMD"; IC=terminal ;;
    Grep|Glob) ing 'Searching files' 'Searched files'; IC=magnifyingglass ;;
    WebSearch) ing 'Searching the web' 'Searched the web'; IC=magnifyingglass ;;
    WebFetch) host=${TI_URL#*://}; host=${host%%/*}; ing "Fetching ${host:-a page}" "Fetched ${host:-a page}"; IC=globe ;;
    Agent|Task) ing "Starting ${TI_NAME:-a subagent}" "Started ${TI_NAME:-a subagent}"; IC='emoji:⤷' ;;
    Skill) ing "Using ${TI_NAME:-a skill}" "Used ${TI_NAME:-a skill}"; IC=sparkles ;;
    TodoWrite) ing 'Updating the plan' 'Updated the plan'; IC=checklist ;;
    mcp__*) t=${t##*__}; ing "Calling $t" "Called $t" ;;
    '') ing 'Working' 'Worked' ;;
    *) ing "Using $t" "Used $t" ;;
  esac
}

# ---- 6. Phase machine -------------------------------------------------------
get phase; PHASE=${V:-idle}
ACT_MAX=40
phase() {
  local act
  get activity_text; act=$V
  PHASE=$1; put phase "$1"
  case "$1" in
    ready)   pill jarvis_activity "Ready" checkmark "$C_DONE" 90 ;;
    working) pill jarvis_activity "Working${act:+: $act}" quote.bubble "$C_WORK" 90 ;;
    waiting) pill jarvis_activity "Waiting${act:+: $act}" bubble.left.fill "$C_WAIT" 90 ;;
    approval) pill jarvis_activity "Needs approval" lock.fill "$C_WAIT" 90 ;;
    done)    pill jarvis_activity "Done${act:+: $act}" hand.thumbsup "$C_DONE" 90 ;;
    error)   pill jarvis_activity "Error${act:+: $act}" exclamationmark.triangle "$C_ERR" 90 ;;
    idle)    unpill jarvis_activity ;;
  esac
}
terminal() { case "$PHASE" in ready|waiting|done|error|idle) return 0 ;; esac; return 1; }
sub_key() { local k=${1//[!A-Za-z0-9._-]/_}; k=${k:0:64}; case "$k" in .*|'') k="x$k" ;; esac; printf '%s' "$k"; }
refs_due() { : > "$SD/refs-due"; [ -n "$CWD" ] && put cwd "$CWD"; }

if [ "$FRESH" = 1 ]; then
  # A tab may still show pills from an earlier writer: mark every key as sent
  # but unknown so the writer clears whatever this event does not set. The old
  # single "jarvis" pill is one of them.
  for k in jarvis jarvis_activity jarvis_tool jarvis_subagents jarvis_pr jarvis_issue; do printf '?' > "$SD/sent/$k"; done
fi

case "$EV" in
  start)
    if [ "$SRC" = compact ]; then :   # a compaction restarts mid-turn: keep everything
    elif [ "$SRC" = resume ]; then
      rm -f "$SD"/sub/* 2>/dev/null
      case "$PHASE" in working|approval|idle) phase "done" ;; *) phase "$PHASE" ;; esac
      refs_due
    else
      rm -f "$SD"/sub/* "$SD/activity_text" "$SD/last_step" "$SD/err" 2>/dev/null
      unpill jarvis_tool
      phase ready
      refs_due
    fi ;;
  prompt)
    [ "$IS_SUB" = 1 ] && exit 0
    act=${PROMPT:0:200}
    act=${act//[[:space:]]/ }
    while [ "${act/  / }" != "$act" ]; do act=${act//  / }; done
    act=${act# }; act=${act% }
    case "$act" in
      '<'*)
        # A harness notification (a finished background task arrives as a
        # prompt of markup) continues the work: keep the ask and last step.
        : ;;
      *)
        rm -f "$SD/err" "$SD/last_step"
        if [ "${#act}" -gt "$ACT_MAX" ]; then act="${act:0:$ACT_MAX}"; act="${act% }..."; fi
        if [ -n "$act" ]; then put activity_text "$act"; else rm -f "$SD/activity_text"; fi ;;
    esac
    unpill jarvis_tool
    phase working ;;
  pre)
    if [ "$IS_SUB" = 1 ]; then
      [ -f "$SD/sub/$(sub_key "$AGENT_ID")" ] && touch "$SD/sub/$(sub_key "$AGENT_ID")"
      terminal && exit 0   # a background subagent after the turn ended
    else
      rm -f "$SD/err"
      if [ "$PHASE" = approval ] || terminal; then phase working; fi
    fi
    describe_tool
    pill jarvis_tool "$D" "$IC" "$C_TOOL" 80 ;;
  post)
    if [ "$IS_SUB" = 1 ]; then terminal && exit 0; fi
    [ "$PHASE" = approval ] && [ "$IS_SUB" = 0 ] && phase working
    if [ "$TOOL_OK" = bad ]; then
      [ "$IS_SUB" = 0 ] && : > "$SD/err"
      pill jarvis_tool "${TOOL##*__} failed" exclamationmark.triangle "$C_ERR" 80
    else
      PAST=1; describe_tool; PAST=
      [ "$IS_SUB" = 0 ] && put last_step "$D"
      pill jarvis_tool "$D" checkmark "$C_TOOL" 80
    fi
    case "$TOOL" in Bash|shell|exec_command|local_shell) case "$TI_CMD" in *git*|*gh\ *) refs_due ;; esac ;; esac ;;
  permission)
    phase approval
    pill jarvis_tool "Needs approval${TOOL:+: ${TOOL##*__}}" lock.fill "$C_WAIT" 80 ;;
  stop)
    [ "$IS_SUB" = 1 ] && exit 0
    get last_step; [ -n "$V" ] && put activity_text "$V"
    q='\?[[:space:]]*$'
    if [[ $RESPONSE =~ $q ]]; then phase waiting
    elif [ -f "$SD/err" ]; then phase error
    else phase "done"
    fi
    unpill jarvis_tool
    refs_due ;;
  sub_start)
    [ -n "$AGENT_ID" ] && printf '%s' "${AGENT_TYPE:-subagent}" > "$SD/sub/$(sub_key "$AGENT_ID")" ;;
  sub_stop)
    [ -n "$AGENT_ID" ] && rm -f "$SD/sub/$(sub_key "$AGENT_ID")" ;;
  end)
    [ "$IS_SUB" = 1 ] && exit 0
    rm -f "$SD"/sub/* "$SD/err" "$SD/last_step" "$SD/activity_text" 2>/dev/null
    PHASE=idle; put phase idle
    for k in jarvis_activity jarvis_tool jarvis_subagents jarvis_pr jarvis_issue; do unpill "$k"; done ;;
esac

# ---- 7. The writer ----------------------------------------------------------
# bounded <secs> <cmd...>: run cmd, killed after <secs>; prints its stdout.
bounded() {
  local secs=$1 out pid killer rc
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/jsb.XXXXXX") || return 1
  "$@" > "$out" 2>/dev/null &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  cat "$out"; rm -f "$out"
  return "$rc"
}
cmux_call() { CMUX_QUIET=1 bounded "${JARVIS_SIDEBAR_CMUX_SECS:-2}" "$CMUX_BIN" "$@" >/dev/null; }

writer_subagents() {
  local f n=0 first=""
  find "$SD/sub" -type f -mmin +"${JARVIS_SIDEBAR_SUBAGENT_TTL_MIN:-120}" -delete 2>/dev/null
  for f in "$SD"/sub/*; do
    [ -f "$f" ] || continue
    n=$((n + 1)); [ -n "$first" ] || { IFS= read -r first < "$f" || true; }
  done
  if [ "$n" -gt 0 ]; then
    pill jarvis_subagents "Subagents: $n running${first:+ ($first)}" 'emoji:⤷' "$C_WORK" 70
  else
    unpill jarvis_subagents
  fi
}

# PR and issue for the session's branch, from gh or the branch name. Runs only
# when an event marked refs due, and at most once per branch per refresh window.
github_web() {  # <remote-url> -> https://github.com/<owner>/<repo>
  local u=${1%.git}
  case "$u" in
    git@github.com:*) u="https://github.com/${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="https://github.com/${u#ssh://git@github.com/}" ;;
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$u"
}
writer_refs() {
  local cwd branch base key old pr num url state iss web now age=999999
  [ -f "$SD/refs-due" ] || return 0
  rm -f "$SD/refs-due"
  get cwd; cwd=$V
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
  branch=$(bounded 2 git -C "$cwd" symbolic-ref --short -q HEAD) || branch=""
  key="$cwd@$branch"
  get refs_key; old=$V
  now=$(date +%s)
  [ -f "$SD/refs_key" ] && age=$(( now - $(stat -c %Y "$SD/refs_key" 2>/dev/null || stat -f %m "$SD/refs_key" 2>/dev/null || echo 0) ))
  [ "$old" = "$key" ] && [ "$age" -lt "${JARVIS_SIDEBAR_REFS_SECS:-120}" ] && return 0
  put refs_key "$key"
  base=$(bounded 2 git -C "$cwd" symbolic-ref --short -q refs/remotes/origin/HEAD) || base=""
  base=${base#origin/}
  if [ -z "$branch" ] || [ "$branch" = "${base:-main}" ] || [ "$branch" = main ] || [ "$branch" = master ]; then
    unpill jarvis_pr; unpill jarvis_issue; return 0
  fi
  num=""; url=""; state=""; iss=""
  if command -v "${JARVIS_SIDEBAR_GH:-gh}" >/dev/null 2>&1; then
    pr=$(cd "$cwd" && bounded "${JARVIS_SIDEBAR_GH_SECS:-5}" "${JARVIS_SIDEBAR_GH:-gh}" pr view "$branch" \
         --json number,url,state,closingIssuesReferences) || pr=""
    if [ -n "$pr" ]; then
      num=$(printf '%s' "$pr" | jq -r '.number // empty' 2>/dev/null)
      url=$(printf '%s' "$pr" | jq -r '.url // empty' 2>/dev/null)
      state=$(printf '%s' "$pr" | jq -r '.state // empty | ascii_downcase' 2>/dev/null)
      iss=$(printf '%s' "$pr" | jq -r '.closingIssuesReferences[0].number // empty' 2>/dev/null)
    fi
  fi
  if [ -n "$num" ]; then
    pill jarvis_pr "PR #$num${state:+ $state}" arrow.triangle.pull "$C_REF" 60 "$url"
  else
    unpill jarvis_pr
  fi
  if [ -z "$iss" ]; then
    re='(^|[/_-])(issue|issues|gh)[-_]?([0-9]+)([^0-9]|$)'
    if [[ $branch =~ $re ]]; then iss=${BASH_REMATCH[3]}
    else re='^([0-9]+)[-_]'; [[ ${branch##*/} =~ $re ]] && iss=${BASH_REMATCH[1]}
    fi
  fi
  if [ -n "$iss" ]; then
    web=""
    if [ -n "$url" ]; then web=${url%/pull/*}
    else web=$(github_web "$(bounded 2 git -C "$cwd" remote get-url origin)") || web=""
    fi
    pill jarvis_issue "Issue #$iss" tag "$C_REF" 55 "${web:+$web/issues/$iss}"
  else
    unpill jarvis_issue
  fi
}

writer_pass() {
  local f k des sent text icon color prio url
  writer_subagents
  writer_refs
  for f in "$SD"/pill/* "$SD"/sent/*; do
    [ -f "$f" ] || continue
    k=${f##*/}
    case "$k" in *.tmp.*) continue ;; esac
    des=""; sent=""
    [ -f "$SD/pill/$k" ] && { IFS= read -r des < "$SD/pill/$k" || true; }
    [ -f "$SD/sent/$k" ] && { IFS= read -r sent < "$SD/sent/$k" || true; }
    [ "$des" = "$sent" ] && continue
    if [ -z "$des" ]; then
      cmux_call clear-status "$k" --workspace "$WS" || continue
    else
      IFS="$US" read -r text icon color prio url <<EOF2
$des
EOF2
      set -- set-status "$k" "$text"
      [ -n "${icon:-}" ] && set -- "$@" --icon "$icon"
      [ -n "${color:-}" ] && set -- "$@" --color "$color"
      [ -n "${prio:-}" ] && set -- "$@" --priority "$prio"
      [ -n "${url:-}" ] && set -- "$@" --url "$url"
      cmux_call "$@" --workspace "$WS" || continue
    fi
    printf '%s' "$des" > "$SD/sent/$k"
  done
}

writer() {
  local tok now pass
  MYPID=$(exec sh -c 'echo $PPID')
  while lock "$SD/.writer.lock" 2; do
    pass=0
    while [ "$pass" -lt 8 ]; do
      pass=$((pass + 1))
      tok=""; [ -f "$SD/dirty" ] && { IFS= read -r tok < "$SD/dirty" || true; }
      writer_pass
      now=""; [ -f "$SD/dirty" ] && { IFS= read -r now < "$SD/dirty" || true; }
      [ "$now" = "$tok" ] && break
    done
    unlock "$SD/.writer.lock"
    # An event that landed between our last pass and the unlock is not lost.
    now=""; [ -f "$SD/dirty" ] && { IFS= read -r now < "$SD/dirty" || true; }
    [ "$now" = "$tok" ] && break
  done
  if [ "$EV" = end ] && [ -z "$(cat "$SD"/sent/* 2>/dev/null)" ]; then
    rm -rf "${ROOT:?}/$WS"   # everything we showed is cleared: forget the surface
  fi
}

unlock "$SD/.phase.lock"; trap - EXIT
printf '%s' "$$.$RANDOM" > "$SD/dirty"
if [ -n "${JARVIS_SIDEBAR_SYNC:-}" ]; then
  writer
else
  ( writer ) </dev/null >/dev/null 2>&1 &
fi
exit 0
