# Jarvis plugins: core and extensions

JarvisAIGeorge ships a core plugin, and each extension (coding today) ships as its own plugin in its own repo.
Both install with the coding tool's own plugin commands. There is no custom installer.

## What ships

| Plugin | Repo | Agents | Skills |
|---|---|---|---|
| `jarvis-ai-george` (core) | this repo, [`plugins/jarvis-ai-george/`](../plugins/jarvis-ai-george/) | `jarvis-ai-george` (manager, standalone file), `reviewer` (read-only) | planning, review and reasoning skills, plus `extension-catalog` and role skills |
| `george-coding-agent` | [georgewangyu/GeorgeCodingAgent](https://github.com/georgewangyu/GeorgeCodingAgent) | `coding` | build, verify, review and ship skills |

The fleet skills under `.agents/skills/` stay where they are.
They drive this repo's `bin/` scripts, so they load when the manager runs from a JarvisAIGeorge home.

## Install: Claude Code

```sh
claude plugin marketplace add georgewangyu/JarvisAIGeorge
claude plugin install jarvis-ai-george@jarvis-ai-george
claude plugin install george-coding-agent@jarvis-ai-george

# The manager is a standalone agent file, because plugin agents ignore initialPrompt, hooks, mcpServers and permissionMode.
mkdir -p ~/.claude/agents
curl -fsSL https://raw.githubusercontent.com/georgewangyu/JarvisAIGeorge/main/plugins/jarvis-ai-george/standalone/jarvis-ai-george.md \
  -o ~/.claude/agents/jarvis-ai-george.md

claude --agent jarvis-ai-george
```

Inside a session, `/plugin marketplace add georgewangyu/JarvisAIGeorge` and `/plugin install <name>@jarvis-ai-george` do the same.

Start a worker as an extension agent:

```sh
claude --agent george-coding-agent:coding
```

To keep an extension off by default and turn it on for one worker only:

```sh
claude plugin disable george-coding-agent@jarvis-ai-george
claude --agent george-coding-agent:coding --settings '{"enabledPlugins":{"george-coding-agent@jarvis-ai-george":true}}'
```

## Install: Codex

```sh
codex plugin marketplace add georgewangyu/JarvisAIGeorge
```

Then install `jarvis-ai-george` and `george-coding-agent` from the Codex plugins directory.
Codex gets the skills only. A Codex worker takes its role from a role skill: say "load role-coding" (or `role-jarvis`, `role-reviewer`) in its brief.
The Codex path is generated but not yet tested end to end.

## Install: any tool, skills only

```sh
npx skills add https://github.com/georgewangyu/JarvisAIGeorge/tree/main/plugins/jarvis-ai-george/skills
npx skills add georgewangyu/GeorgeCodingAgent
```

## How it is built

One source per piece, one build script per repo, and generated adapters that CI checks.

- Sources: [`jarvis-build.json`](../jarvis-build.json), the plugin manifest `plugins/jarvis-ai-george/jarvis-extension.json`, agent sources in `plugins/jarvis-ai-george/agents-src/` (each with a short `rules:` list inlined at build), and `skills/`.
- Build: `python3 tools/jarvis-build.py` writes the Claude agent files, the standalone manager, role skills, `extension-catalog`, both plugin manifests, both marketplaces, and the plugin's `AGENTS.md` plus `CLAUDE.md`.
- Check: `python3 tools/jarvis-build.py --check` fails on a stale output, a bad skill frontmatter, a skill missing from the manifest, or a skill name owned by two plugins. The `jarvis-plugin-check` workflow runs it with the scrub gate.
- Known extensions: vendored manifests in `plugins/jarvis-ai-george/extensions/`. Refresh with `python3 tools/jarvis-build.py --fetch`.

## Writing an extension

1. A repo with `jarvis-build.json`, `jarvis-extension.json` (schema 1), `agents-src/`, `skills/`, and a copy of `tools/jarvis-build.py`.
2. The manifest: `id`, `name`, `schema`, `version`, `description`, `repo`, `agents` (`name`, `summary`, `dispatch_when`), `skills`, `relies_on_core`, `requires`. No tool-specific fields.
3. Skill split: a skill goes in core if the manager uses it, or roles in two or more extensions use it. Otherwise it lives in the extension that uses it.
4. In this repo, classify every new Markdown or text file in `docs/documentation-audiences.json` (the inherited doc-audience check fails otherwise).
5. Add the repo to `peers` in this repo's `jarvis-build.json` and run `--fetch` so the catalog and the marketplace list it.

## What loads where (Claude Code, verified)

| Piece | Loaded? |
|---|---|
| `--agent <plugin>:<agent>` prompt | yes, as the system prompt |
| A plugin skill when that plugin is enabled only for this launch via `--settings` | yes |
| Plugin `SessionStart` hook output | yes in the main session, not in Agent-tool subagents |
| A plugin's own `CLAUDE.md` or `AGENTS.md` | no |
| Agent `skills:` preload | in subagents only; as the main session, the agent loads them itself (the manager uses `initialPrompt`) |
| A marketplace entry pointing at another GitHub repo | yes |
