#!/usr/bin/env bash
# bin/fm-display-title-lib.sh - the human title a worker tab shows after the
# worker mark, for example "Reviewer: Check startup flow".
#
# Display only. A display title is never an identifier: two tasks may share
# one, nothing looks a task up by it, and recovery, routing, teardown, reboot
# heal and board lookups keep using the task id and the scoped label
# fm-<hometag>-<id> (issue #16's exactly-one-match rule applies to the label
# only). bin/fm-spawn.sh records it as display_title= in the task meta;
# docs/cmux-backend.md "Worker titles" owns the operator view.
#
# Source order: an explicit title (fm-spawn --title), else the brief's title
# (a `title:` frontmatter line, else the first line under "## Captain's intent",
# else the first heading that is not a scaffold heading), else the task id. The
# role from --agent (the agent part of <plugin>:<agent>, made readable) leads
# it. The result is one line of at most FM_DISPLAY_TITLE_MAX (default 50)
# characters.

FM_DISPLAY_TITLE_MAX=${FM_DISPLAY_TITLE_MAX:-50}

# One clean line: no control characters, no markdown lead-in, single spaces.
fm_display_title_clean() {  # <text>
  local t
  t=$(printf '%s' "$1" | head -1 | LC_ALL=C tr -d '\000-\010\013-\037\177' | tr '\t' ' ')
  # shellcheck disable=SC2016 # backticks here are literal markdown, not expansions
  t=$(printf '%s' "$t" | sed -E 's/^[[:space:]#>*`-]+//; s/[`*]+//g; s/[[:space:]]+/ /g; s/[[:space:]]+$//')
  printf '%s' "$t"
}

# "george-coding-agent:reviewer" -> "Reviewer"; "code_review" -> "Code Review".
fm_display_title_role() {  # <agent>
  local a=${1##*:}
  [ -n "$a" ] || return 0
  printf '%s' "$a" | tr '_-' '  ' | awk '{for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print}'
}

fm_display_title_from_brief() {  # <brief-file>
  local f=$1 line
  [ -f "$f" ] || return 0
  line=$(awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm && /^title:[[:space:]]*/ { sub(/^title:[[:space:]]*/, ""); gsub(/^["\x27]|["\x27]$/, ""); if ($0 != "") { print; exit } }
    fm { next }
    /^## Captain.s intent[[:space:]]*$/ { intent = 1; next }
    intent && /^#/ { intent = 0 }
    intent && NF && $0 !~ /^\{TASK\}$/ { print; exit }
  ' "$f" 2>/dev/null)
  if [ -z "$line" ]; then
    line=$(grep -E '^#{1,3} ' "$f" 2>/dev/null \
      | grep -Evi '^#+ (task|setup|rules|definition of done|captain.s intent|firstmate spec|context|objective|plan|constraints)[[:space:]]*$' | head -1)
  fi
  fm_display_title_clean "$line"
}

fm_display_title() {  # <id> <agent> <brief-file> <explicit>
  local id=$1 agent=$2 brief=$3 t role max=$FM_DISPLAY_TITLE_MAX
  t=$(fm_display_title_clean "${4:-}")
  [ -n "$t" ] || t=$(fm_display_title_from_brief "$brief")
  [ -n "$t" ] || t=$id
  role=$(fm_display_title_role "$agent")
  if [ -n "$role" ]; then
    case "$t" in "$role:"*|"$role "*) ;; *) t="$role: $t" ;; esac
  fi
  case "$max" in ''|*[!0-9]*) max=50 ;; esac
  if [ "${#t}" -gt "$max" ]; then
    t="${t:0:$((max - 3))}"
    t="${t%"${t##*[! ]}"}..."
  fi
  printf '%s' "$t"
}

# fm-spawn's choice: a relaunch keeps its recorded title unless an explicit one
# replaces it; otherwise derive it.
fm_display_title_resolve() {  # <id> <agent> <brief-file> <explicit> [<relaunch-meta>]
  local t=""
  if [ -n "${5:-}" ] && [ -z "$4" ] && [ -f "$5" ]; then
    t=$(sed -n 's/^display_title=//p' "$5" | tail -1)
  fi
  [ -n "$t" ] || t=$(fm_display_title "$1" "$2" "$3" "$4")
  printf '%s' "$t"
}
