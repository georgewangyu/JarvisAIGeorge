#!/bin/bash
# mistake-miner capture hook (UserPromptSubmit). Appends one stub line to
# <dir>/inbox-stubs.md when the user's prompt looks like a correction.
# Contract: pure bash (bash 3.2 safe, no python: its cold start is ~70 ms),
# prints nothing, never blocks, exits 0 on every path.
# Skips: MISTAKE_MINER_CAPTURE=off (set it for worker or subagent sessions),
# machine prompts (start with "<" or a brief/wake line), and prompts that look
# like they hold a secret.
# Dir: $MISTAKE_MINER_DIR, else dir= in $MISTAKE_MINER_CONFIG or
# ~/.config/mistake-miner/config, else ~/.mistake-miner.

_mm_main() {
  [ "${MISTAKE_MINER_CAPTURE:-on}" = off ] && return 0
  local j="" line
  while IFS= read -r line || [ -n "$line" ]; do j="$j$line "; done
  case "$j" in *'"prompt"'*) ;; *) return 0 ;; esac

  # Pull a JSON string field without a parser. Escapes are kept as-is; a stub
  # is a pointer for later classification, not a faithful copy.
  _mm_field() {
    local v=${j#*\"$1\"}
    [ "$v" = "$j" ] && { _mm_v=""; return; }
    v=${v#*:}; v=${v#"${v%%[!\ ]*}"}; v=${v#\"}
    v=${v:0:600}
    local out="" rest=$v
    while [ -n "$rest" ]; do
      case "$rest" in
        \\\"*) out="$out\""; rest=${rest:2} ;;
        \\n*|\\t*|\\r*) out="$out "; rest=${rest:2} ;;
        \\*) out="$out${rest:0:2}"; rest=${rest:2} ;;
        \"*) break ;;
        *) out="$out${rest:0:1}"; rest=${rest:1} ;;
      esac
    done
    _mm_v=$out
  }
  _mm_field prompt; local p=$_mm_v
  p=${p#"${p%%[![:space:]]*}"}
  [ ${#p} -lt 3 ] && return 0
  case "$p" in "<"*|"Read and execute the brief"*|"Wake:"*) return 0 ;; esac

  shopt -s nocasematch
  # Secret-looking prompts are never logged.
  if [[ $p =~ (AKIA[0-9A-Z]{16}|-----BEGIN|ghp_[A-Za-z0-9]|xox[abp]-|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=]|[A-Za-z0-9+/=_-]{40,}) ]]; then
    return 0
  fi
  local re="^(no|nope|wrong|stop)([[:space:][:punct:]]|$)|(^|[^a-z])(don'?t|do not|wrong|i said|that'?s not|why did you|you forgot|again|stop (doing|using|adding|asking))([^a-z]|$)"
  [[ $p =~ $re ]] || return 0
  shopt -u nocasematch

  _mm_field session_id; local sid=${_mm_v:0:8}
  _mm_field cwd; local cwd=$_mm_v

  local dir="${MISTAKE_MINER_DIR:-}" cfg
  if [ -z "$dir" ]; then
    for cfg in "${MISTAKE_MINER_CONFIG:-}" "$HOME/.config/mistake-miner/config"; do
      [ -n "$cfg" ] && [ -f "$cfg" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in dir=*) dir=${line#dir=}; break ;; esac
      done < "$cfg"
      [ -n "$dir" ] && break
    done
  fi
  dir=${dir:-$HOME/.mistake-miner}
  dir=${dir/#\~/$HOME}
  mkdir -p "$dir" 2>/dev/null || return 0

  p=${p:0:200}; p=${p//|//}; cwd=${cwd//|//}
  local ts; ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null) || ts=-
  local id="s$(date '+%s' 2>/dev/null)-$$"
  local f="$dir/inbox-stubs.md"
  if [ ! -f "$f" ]; then
    printf '# Mistake-miner capture stubs\n\nRaw correction-looking prompts from the capture hook. The daily harvest classifies them (real correction vs redirect). Do not edit.\n\n| time | id | session | cwd | prompt (first 200 chars) |\n|---|---|---|---|---|\n' > "$f" 2>/dev/null || return 0
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$ts" "$id" "$sid" "$cwd" "$p" >> "$f" 2>/dev/null
  return 0
}
_mm_main 2>/dev/null
exit 0
