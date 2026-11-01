# Jarvis plugins: core and extensions

JarvisAIGeorge ships a core plugin, and each extension (coding today) ships as its own plugin in its own repo.
Both install with the coding tool's own plugin commands. There is no custom installer.

## What ships

| Plugin | Repo | Agents | Skills |
|---|---|---|---|
| `jarvis-ai-george` (core) | this repo, [`plugins/jarvis-ai-george/`](../plugins/jarvis-ai-george/) | `jarvis-ai-george` (manager: a project agent in `.claude/agents/` and a standalone file) | `extension-catalog`, `role-jarvis`, `brainstorm`, `grill-me`, the four `principles*` skills, `mistake-miner` |
| `george-coding-agent` | [georgewangyu/GeorgeCodingAgent](https://github.com/georgewangyu/GeorgeCodingAgent) | `coding`, `reviewer` (read-only: Read, Grep, Glob) | planning, spec, build, verify, review and ship skills, `role-coding`, `role-reviewer` |

Dependencies point one way. Core knows the extensions through `extension-catalog`; an extension never depends on or references core, and works on its own.
No skill or agent ships in two plugins (the build fails on a duplicate name).

The fleet skills under `.agents/skills/` stay where they are.
They drive this repo's `bin/` scripts, so they load when the manager runs from a JarvisAIGeorge home.

## Install: Claude Code

The clone flow in [`install.md`](install.md) is the default: clone, `cd ~/jarvis && claude`, approve in chat.
By hand, without a home:

```sh
claude plugin marketplace add georgewangyu/JarvisAIGeorge
claude plugin install jarvis-ai-george@jarvis-ai-george
claude plugin install george-coding-agent@jarvis-ai-george

# The manager is an agent file (plugin agents ignore initialPrompt, hooks, mcpServers and permissionMode).
mkdir -p ~/.claude/agents
curl -fsSL https://raw.githubusercontent.com/georgewangyu/JarvisAIGeorge/main/plugins/jarvis-ai-george/standalone/jarvis-ai-george.md \
  -o ~/.claude/agents/jarvis-ai-george.md
claude --agent jarvis-ai-george
```

The coding extension alone, from its own marketplace:

```sh
claude plugin marketplace add georgewangyu/GeorgeCodingAgent
claude plugin install george-coding-agent@george-coding-agent
claude --agent george-coding-agent:coding
```

To keep an extension off by default and turn it on for one worker only:

```sh
claude plugin disable george-coding-agent@jarvis-ai-george
claude --agent george-coding-agent:coding --settings '{"enabledPlugins":{"george-coding-agent@jarvis-ai-george":true}}'
```

Plugins update by version: bump `version` in the manifest when a change should reach installed copies.

## Install: Codex

```sh
codex plugin marketplace add georgewangyu/JarvisAIGeorge
codex plugin add jarvis-ai-george@jarvis-ai-george
codex plugin add george-coding-agent@jarvis-ai-george
```

In a JarvisAIGeorge home, `bin/jarvis-setup.sh plugins` and `extensions george-coding-agent` run these after your yes; [Using Codex](install.md#using-codex) has the full flow.
Codex gets the skills. A Codex worker takes its role from a role skill on its brief's first line: "Load `$role-coding` first" (or `$role-jarvis`, `$role-reviewer`).
The reviewer's read-only tools are not enforced in Codex; `codex exec --sandbox read-only` enforces them for a standalone review.
The manifests are validated against Codex's schema in CI (`tests/jarvis-codex-manifests.test.sh`); the Codex path is not yet run end to end.

## Install: any tool, skills only

```sh
npx skills add https://github.com/georgewangyu/JarvisAIGeorge/tree/main/plugins/jarvis-ai-george/skills
npx skills add georgewangyu/GeorgeCodingAgent
```

## How it is built

One source per piece, one build script per repo, and generated adapters that CI checks.

- Sources: [`jarvis-build.json`](../jarvis-build.json), the plugin manifest `plugins/jarvis-ai-george/jarvis-extension.json`, agent sources in `plugins/jarvis-ai-george/agents-src/` (each with a short `rules:` list inlined at build), and `skills/`.
- Build: `python3 tools/jarvis-build.py` writes the Claude agent files, the standalone manager and its project copy in `.claude/agents/` (`project_agents_dir`), role skills, `extension-catalog`, both plugin manifests, both marketplaces, and the plugin's `AGENTS.md` plus `CLAUDE.md`.
- Check: `python3 tools/jarvis-build.py --check` fails on a stale output, a bad skill frontmatter, a skill missing from the manifest, or a skill name owned by two plugins. The `jarvis-plugin-check` workflow runs it with the scrub gate.
- Known extensions: vendored manifests in `plugins/jarvis-ai-george/extensions/`. Refresh with `python3 tools/jarvis-build.py --fetch`.

## Writing an extension

1. A repo with `jarvis-build.json`, `jarvis-extension.json` (schema 1), `agents-src/`, `skills/`, and a copy of `tools/jarvis-build.py`.
2. The manifest: `id`, `name`, `schema`, `version`, `description`, `repo`, `agents` (`name`, `summary`, `dispatch_when`), `skills`, `requires`. No tool-specific fields. Keep `relies_on_core` empty: an extension must work alone.
3. Skill split: core holds only what the manager itself uses. Everything a worker uses lives in its extension. Mention a skill from another plugin only as optional ("if installed").
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
| Repo `.claude/settings.json` `agent` | yes: plain `claude` in the folder starts that agent; a subfolder that is its own repo (`projects/<x>`) does not inherit it |
| Repo `extraKnownMarketplaces` plus `enabledPlugins` on folder trust | the marketplace is added and a same-repo plugin is loaded with no extra prompt; a plugin whose source is another repo is not installed |
| Project agent frontmatter `hooks` | yes, active while that agent is the session (the write guard) |
| Plugin update | by version only; the same version means no update |
