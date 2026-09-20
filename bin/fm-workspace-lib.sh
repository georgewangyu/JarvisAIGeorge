# shellcheck shell=bash
# Workspace checkout isolation mode helpers.
# Owner for config/workspace-isolation parsing.

fm_workspace_isolation_mode() {  # [config-dir]
  local config=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}} file line value seen=0
  file="$config/workspace-isolation"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'shared-checkout\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo "error: config/workspace-isolation must be a regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    value=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$value" ] || continue
    if [ "$seen" -ne 0 ]; then
      echo "error: config/workspace-isolation must contain exactly one value" >&2
      return 1
    fi
    seen=1
    case "$value" in
      shared-checkout|worktree) ;;
      *) echo "error: invalid config/workspace-isolation '$value' (expected shared-checkout or worktree)" >&2; return 1 ;;
    esac
    printf '%s\n' "$value"
  done < "$file"
  if [ "$seen" -eq 0 ]; then
    echo "error: config/workspace-isolation is empty (expected shared-checkout or worktree)" >&2
    return 1
  fi
}

fm_workspace_uses_shared_checkout() {  # [config-dir]
  [ "$(fm_workspace_isolation_mode "$@")" = shared-checkout ]
}
