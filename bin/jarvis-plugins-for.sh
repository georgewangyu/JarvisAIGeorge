#!/usr/bin/env bash
# bin/jarvis-plugins-for.sh - print the Claude Code settings JSON that gives one
# launch its plugin shape (docs/jarvis-plugins.md "Skill listing budget").
#
# Usage:
#   bin/jarvis-plugins-for.sh --manager      core on, every known extension off
#   bin/jarvis-plugins-for.sh <extension-id> core and that extension on, every
#                                            other known extension off
#   bin/jarvis-plugins-for.sh --map <...>    print only the enabledPlugins
#                                            object, for merging into settings
#
# Known extensions are the vendored manifests in
# plugins/jarvis-ai-george/extensions/<id>.json. Each extension is switched
# under both marketplace names it can be installed from (jarvis-ai-george and
# its own id), so the shape holds however it was installed. The output never
# installs or uninstalls anything and never touches the user's own settings:
# it is passed per launch with `claude --settings`.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
CORE=jarvis-ai-george
MARKET=jarvis-ai-george
EXT_DIR="${JARVIS_EXTENSIONS_DIR:-$ROOT/plugins/jarvis-ai-george/extensions}"

map_only=0
if [ "${1:-}" = --map ]; then map_only=1; shift; fi
want=${1:-}
[ -n "$want" ] || { echo "usage: jarvis-plugins-for.sh [--map] --manager|<extension-id>" >&2; exit 2; }

ids=()
for f in "$EXT_DIR"/*.json; do
  [ -f "$f" ] || continue
  ids+=("$(basename "$f" .json)")
done

if [ "$want" != --manager ]; then
  found=0
  for id in "${ids[@]}"; do [ "$id" = "$want" ] && found=1; done
  printf '%s' "$want" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || { echo "jarvis-plugins-for: bad extension id '$want'" >&2; exit 2; }
  [ "$found" = 1 ] || ids+=("$want")
fi

entries="\"$CORE@$MARKET\":true"
for id in "${ids[@]}"; do
  on=false
  [ "$id" = "$want" ] && on=true
  entries="$entries,\"$id@$MARKET\":$on,\"$id@$id\":$on"
done

if [ "$map_only" = 1 ]; then
  printf '{%s}\n' "$entries"
else
  printf '{"enabledPlugins":{%s}}\n' "$entries"
fi
