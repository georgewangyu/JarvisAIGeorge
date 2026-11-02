#!/usr/bin/env bash
# bin/fm-skill-catalog-check.sh - classify a worker's startup screen for an
# incomplete skill catalog (the harness dropped skill descriptions or omitted
# skills because the installed catalog exceeded its skills context budget).
#
# Usage:
#   bin/fm-skill-catalog-check.sh [file]    read a pane capture (default stdin)
#
# Output: nothing when the capture shows no catalog warning. Otherwise one line:
#   SKILL_CATALOG_INCOMPLETE: <what the harness reported>; the worker may not
#   see every skill. Name the role and execution skills explicitly in the
#   brief ($role-<agent> and $<skill> on Codex) or have it read the plugin's
#   router skill. See docs/jarvis-plugins.md "Skill listing budget".
#
# Exit status is always 0 unless the input cannot be read (2): this is a
# readiness diagnostic, never a launch gate.
#
# This is a different limit from the project-document byte budget (AGENTS.md,
# tests/fm-agents-md-size.test.sh): that one truncates instruction files, this
# one trims the skill list. The patterns match the wording Codex CLI 0.166.0
# used ("skills context budget ... exceeded", "descriptions were removed",
# "N additional skills were omitted"); they are kept loose so a reworded panel
# still trips them, and a capture with no skill and budget words never does.

set -u

src=${1:--}
if [ "$src" = - ]; then
  text=$(cat) || exit 2
else
  [ -r "$src" ] || { echo "fm-skill-catalog-check: cannot read $src" >&2; exit 2; }
  text=$(cat "$src")
fi

# Box-drawing borders and other non-ASCII glyphs become spaces, and the panel's
# line wraps are joined, so a phrase split across a bordered panel still matches.
hits=$(printf '%s\n' "$text" | LC_ALL=C sed 's/[^ -~]/ /g' | tr -s '[:space:]' ' ' | grep -ioE \
  "skills? (context )?budget[^.]{0,80}(exceed|overflow)[a-z]*|(all )?skill descriptions? (were |was )?(removed|stripped|truncated|dropped)|[0-9]+ (additional |more )?skills? (were |was )?(omitted|hidden|dropped|not shown)" \
  | head -3 | tr '\n' ';' | sed 's/;$//; s/;/; /g')

[ -z "$hits" ] && exit 0
echo "SKILL_CATALOG_INCOMPLETE: $hits; the worker may not see every skill. Name the role and execution skills explicitly in the brief (\$role-<agent> and \$<skill> on Codex) or have it read the plugin's router skill. See docs/jarvis-plugins.md \"Skill listing budget\"."
exit 0
