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

## Skill listing budget

Every coding tool shows the model a list of installed skills with their descriptions, and that list has a budget.
Claude Code 2.1.316 gives it about 1% of the context window in characters (about 8,000 at 200K tokens; `skillListingBudgetFraction` and `skillListingMaxDescChars` in settings) and cuts descriptions when the list is over.
Codex CLI 0.166.0 strips every description and omits skills when its skills context budget is exceeded.
The user's other plugins share the same budget, so each Jarvis plugin keeps its share small and fixed.
This is a different limit from the project-document byte budget, which truncates `AGENTS.md` (see `tests/fm-agents-md-size.test.sh`).

The pattern, enforced by `tools/jarvis-build.py --check`:

1. **One router per extension.** The build generates an always-listed router skill from the manifest: `<id>-skills` for an extension, `extension-catalog` for core. It lists every skill with a one-line summary (the first sentence of its description) and its file path. Nobody maintains the list by hand.
2. **Listed skills.** Only the router, each agent's preload skills, and the manifest's optional `listed` array stay in the skill list.
3. **Hidden skills.** Every other skill carries `disable-model-invocation: true`, which the build writes into the skill's frontmatter. Claude Code then drops it from the list, but it stays reachable: the model loads the router and reads `../<skill>/SKILL.md`. A user can still type its slash command. Generated agents get a session-start line naming their router.
4. **Fixed budgets.** Listed descriptions are at most 200 characters, every description at most 250, and one plugin's listed entries (name plus description) at most 1,000 characters. The combined budget for core plus every known extension (vendored in `plugins/jarvis-ai-george/extensions/`) is 5,000 characters. All four numbers live in `jarvis-build.json` under `listing`. A manifest may declare a lower `listing_budget`, never a higher one.
5. **Proof.** `tests/jarvis-skill-budget.test.sh` builds a synthetic extension with 100 skills. It checks that two are listed, all 100 are reachable through the router, listing all of them is refused, and the combined budget fails at six plugins and passes at four.

In a home, the FirstMate skills under `.agents/skills/` follow the same rule: the user-invocable ones (`afk`, `ahoy`, `bearings`, `quiet`, `stow`, `updatefirstmate`) stay listed, and the agent-only ones are hidden with `AGENTS.md` section 13 as their router.

### Tools that cannot hide skills or enable plugins per launch

Claude Code can scope an extension to one worker (`--settings '{"enabledPlugins":{...}}'`), so a worker sees only the plugins it needs.
Codex cannot enable a plugin for one launch, and it does not honor `disable-model-invocation`, so every installed skill competes for its budget.
The fallback there is router-only discovery plus explicit loading:

- A Codex worker's brief names its role and execution skills explicitly on the first lines (`Load $role-coding first`, then `$incremental-implementation` and the others it needs). An explicit `$skill` mention does not depend on the listing.
- Anything else, it finds through the plugin's router.
- `bin/fm-skill-catalog-check.sh` reads a worker's startup screen, and `bin/fm-spawn.sh` runs it after every Codex spawn. When the warning panel is there, the spawn prints `SKILL_CATALOG_INCOMPLETE:`, and the manager makes sure the brief names the skills the task needs.
- The user's global skills are never deleted, disabled or rewritten. To free budget, uninstall or disable unused plugins with the tool's own commands.

Verify on a personal laptop (Codex is not run on the work machine): that an explicit `$skill` mention loads a skill Codex omitted from the list, and the exact wording of its overflow panel.

## Writing an extension

1. A repo with `jarvis-build.json`, `jarvis-extension.json` (schema 1), `agents-src/`, `skills/`, and a copy of `tools/jarvis-build.py`.
2. The manifest: `id`, `name`, `schema`, `version`, `description`, `repo`, `agents` (`name`, `summary`, `dispatch_when`), `skills`, `requires`. No tool-specific fields. Keep `relies_on_core` empty: an extension must work alone.
3. Skill split: core holds only what the manager itself uses. Everything a worker uses lives in its extension. Mention a skill from another plugin only as optional ("if installed").
4. In this repo, classify every new Markdown or text file in `docs/documentation-audiences.json` (the inherited doc-audience check fails otherwise).
5. Add the repo to `peers` in this repo's `jarvis-build.json` and run `--fetch` so the catalog and the marketplace list it.
6. Keep within the skill listing budget above: list only the skills the agents preload or that must be auto-discovered, keep descriptions short, and let the generated router index the rest. A new extension with a hundred skills costs the same listed budget as one with five.

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
