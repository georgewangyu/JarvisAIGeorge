# JarvisAIGeorge plugins: core and extensions

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
The user's other plugins share the same budget, so each JarvisAIGeorge plugin keeps its share small and fixed.
This is a different limit from the project-document byte budget, which truncates `AGENTS.md` (see `tests/fm-agents-md-size.test.sh`).

Routing has two levels, and each launch shape has its own budget, so adding extensions (a video agent, a writing agent, each with a hundred skills) never runs into a shared total.

```
manager launch:  core only           -> extension-catalog: one line per agent, core skills
worker launch:   core + its own ext  -> that extension's router and its few listed skills
                                     -> every other skill of the extension, by path, via the router
```

1. **Level 1, the manager sees agents.** The manager launches with core on and every known extension off (the repo's `.claude/settings.json`, and `bin/jarvis-launch` from another folder). `extension-catalog`, generated from the vendored manifests in `plugins/jarvis-ai-george/extensions/`, has one short line per agent: what it does and when to dispatch it. It never lists extension skills or routers. The manager's skill list stays the same size; the catalog body grows by one line per agent and one install line per extension.
2. **Level 2, a worker sees its own extension.** `bin/fm-spawn.sh --agent <plugin>:<agent>` gives the worker core plus only that plugin, and every other known extension off. It merges the map from `bin/jarvis-plugins-for.sh <plugin>` into the worker's `--settings`. The user's own settings are untouched, and each extension is switched under both marketplace names it can come from.
3. **One router per extension.** The build generates an always-listed router skill from the manifest (`<id>-skills`). It lists every skill with a one-line summary (the first sentence of its description) and its file path. Nobody maintains the list by hand.
4. **Listed and hidden skills.** Only the router, each agent's preload skills, and the manifest's optional `listed` array stay in the list. Every other skill carries `disable-model-invocation: true`, which the build writes into its frontmatter. Claude Code drops it from the list, and the model reaches it by loading the router and reading `../<skill>/SKILL.md`. A user can still type its slash command. Generated agents get a session-start line naming their router.
5. **Budgets per launch shape** (`jarvis-build.json` `listing`):
   - listed description at most 200 characters, any description at most 250;
   - one extension's listed entries (name plus description) at most 1,000;
   - manager shape (core's listed entries) at most 1,500;
   - each agent's shape (core plus its own extension's capped share) at most 2,500;
   - each catalog line at most 220.

   An extension's build checks its own share; core's build checks the manager shape and every known agent's shape. A manifest may declare a lower `listing_budget`, never a higher one.
6. **Proof.** `tests/jarvis-skill-budget.test.sh`:
   - a 100-skill extension lists two skills and reaches all 100 through its router, and listing all 100 is refused;
   - ten 100-skill extensions added one by one: the catalog gains one agent line each, the manager's listed share stays constant, every agent's shape fits, every skill is reachable through its own router, and nothing fails on extension count;
   - the repo settings are the manager shape.

   Live check (Claude Code 2.1.316): the manager shape listed only the three core skills. A coding worker's shape added the coding router and its four listed skills, and the hidden skills stayed hidden.

In a home, the FirstMate skills under `.agents/skills/` follow the same rule: the user-invocable ones (`afk`, `ahoy`, `bearings`, `quiet`, `stow`, `updatefirstmate`) stay listed, and the agent-only ones are hidden with `AGENTS.md` section 13 as their router.

### Tools that cannot hide skills or enable plugins per launch

Claude Code scopes plugins per launch (`--settings` `enabledPlugins`), which is what level 2 relies on.
Codex has no per-launch plugin switch that we know of, and it does not honor `disable-model-invocation`, so every installed plugin's skills compete in every Codex session, manager and worker alike.
The fallback there is to keep the set small and route explicitly:

- Install in Codex only the extensions you use there; the shared budget then grows with that set, not with everything known.

- A Codex worker's brief names its role and execution skills explicitly on the first lines (`Load $role-coding first`, then `$incremental-implementation` and the others it needs). An explicit `$skill` mention does not depend on the listing.
- Anything else, it finds through the plugin's router.
- `bin/fm-skill-catalog-check.sh` reads a worker's startup screen, and `bin/fm-spawn.sh` runs it after every Codex spawn. When the warning panel is there, the spawn prints `SKILL_CATALOG_INCOMPLETE:`, and the manager makes sure the brief names the skills the task needs.
- The user's global skills are never deleted, disabled or rewritten. To free budget, uninstall or disable unused plugins with the tool's own commands.

Verify on a personal laptop (Codex is not run on the work machine): whether Codex has a per-launch plugin switch (if it has, wire it like level 2), that an explicit `$skill` mention loads a skill Codex omitted from the list, and the exact wording of its overflow panel.

## Writing an extension

1. A repo with `jarvis-build.json`, `jarvis-extension.json` (schema 1), `agents-src/`, `skills/`, and a copy of `tools/jarvis-build.py`.
2. The manifest: `id`, `name`, `schema`, `version`, `description`, `repo`, `agents` (`name`, `summary`, `dispatch_when`), `skills`, `requires`. No tool-specific fields. Keep `relies_on_core` empty: an extension must work alone.
3. Skill split: core holds only what the manager itself uses. Everything a worker uses lives in its extension. Mention a skill from another plugin only as optional ("if installed").
4. In this repo, classify every new Markdown or text file in `docs/documentation-audiences.json` (the inherited doc-audience check fails otherwise).
5. Add the repo to `peers` in this repo's `jarvis-build.json` and run `--fetch` so the catalog and the marketplace list it.
6. Keep within the skill listing budget above: give every agent a unique name (its role skill is `role-<agent>`), a one-line `summary` and `dispatch_when` for the catalog, list only the skills the agents preload or that must be auto-discovered, keep descriptions short, and let the generated router index the rest. A new extension with a hundred skills costs the manager one catalog line per agent.

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
