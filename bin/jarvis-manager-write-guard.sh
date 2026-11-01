#!/usr/bin/env bash
# bin/jarvis-manager-write-guard.sh - Claude Code PreToolUse hook for the Jarvis
# manager session: refuse MCP tools that look like writes, so the manager
# dispatches a worker instead of changing a live system from its own thread.
#
# Wiring: the manager agent's frontmatter `hooks` (agents-src/jarvis-ai-george.md)
# runs this for matcher `mcp__.*`, so it is active only while the manager agent
# is the session. Workers never load it.
#
# Input: the hook JSON on stdin. Only tool_name and, when present, a top-level
# string field named action, operation, method or mode in tool_input are read.
# A call is a write when any word of those values is on the write list.
# Words are split on non-letters and camelCase: `mcp__srv__post_message` ->
# post, message; `CRAddComment` -> cr, add, comment. Plurals do not match, so
# `list_comments` stays a read.
#
# Write list: config/manager-write-words (one word per line, # comments) under
# FM_HOME or this repo, else the built-in default below. Edit that file to add
# or drop words. An empty file disables the guard.
# Off for one session: JARVIS_MANAGER_WRITE_GUARD=off.
#
# Output: on a write, a PreToolUse deny decision with the reason; otherwise
# nothing (exit 0, the normal permission flow continues). No dependencies
# beyond bash, grep, sed and tr.

set -u

DEFAULT_WORDS="create update delete send post comment deploy publish merge resolve write edit remove"

[ "${JARVIS_MANAGER_WRITE_GUARD:-on}" = off ] && exit 0

input=$(cat)

script_dir=$(cd "$(dirname "$0")" && pwd)
home="${FM_HOME:-$(dirname "$script_dir")}"
words_file="${JARVIS_MANAGER_WRITE_WORDS:-$home/config/manager-write-words}"

if [ -f "$words_file" ]; then
  words=$(sed -e 's/#.*//' "$words_file" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:],' '\n' | grep -v '^$' || true)
  [ -z "$words" ] && exit 0
else
  words=$(printf '%s' "$DEFAULT_WORDS" | tr ' ' '\n')
fi

# Pull a top-level "key": "value" string out of the hook JSON. Tool names and
# action verbs never contain quotes, so a plain pattern is enough.
json_str() {  # <key>
  printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed -e 's/^.*:[[:space:]]*"//' -e 's/"$//'
}

tool=$(json_str tool_name)
case "$tool" in
  mcp__*) ;;
  *) exit 0 ;;
esac

# The tool's own name is the part after the last "__" (server names may hold
# write-looking words, such as a "deploy-tools" server, so skip them).
short=${tool##*__}
subject="$short"
for key in action operation method mode; do
  v=$(json_str "$key")
  [ -n "$v" ] && subject="$subject $v"
done

tokens=$(printf '%s' "$subject" | sed -e 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g' -e 's/\([A-Z]\)\([A-Z][a-z]\)/\1 \2/g' \
  | tr -c '[:alpha:]' '\n' | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)

hit=
for t in $tokens; do
  if printf '%s\n' "$words" | grep -qx -- "$t"; then
    hit=$t
    break
  fi
done
[ -z "$hit" ] && exit 0

reason="Jarvis manager write guard: '$tool' looks like a write ('$hit'). The manager does not change live systems from its own thread. Dispatch a worker with this change in its brief. Reads and searches stay allowed. Word list: config/manager-write-words."
reason=$(printf '%s' "$reason" | sed 's/["\\]/\\&/g')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
