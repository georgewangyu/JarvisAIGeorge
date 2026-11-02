# Startup warnings: who owns each one

A Claude Code or Codex session can open with several unrelated warnings at once.
Most are not Jarvis or fleet failures: a working manager can start with an optional service down or an old key in your config.
Sort each warning by owner first, then act on the ones you own.

## Three sources that do not agree

- **The native warning panel** (Codex: "N warnings, F2 to view"; Claude Code: the startup notices) lists what that tool noticed while starting this session.
- **The doctor summary** (`codex doctor --summary --ascii`, `claude doctor`) checks configuration and services on demand. Its counts and categories differ from the panel, because it runs different checks at a different time.
- **Raw log rows** repeat one problem many times, once per retry.

Count and fix warnings by kind, not by number. To read the Codex panel in cmux without touching input, see [`install.md`](install.md) "Reading a Codex warning panel in cmux".

## By owner

| Owner | What it looks like | Who acts | Action |
|---|---|---|---|
| **Jarvis (this project)** | A warning that names `jarvis-ai-george`, `george-coding-agent`, this repo's `AGENTS.md`, `.claude/settings.json`, `.codex/hooks.json` or `bin/` | Us | File an issue on this repo with the exact text. Known and fixed: hook timeout clamps ([#8](https://github.com/georgewangyu/JarvisAIGeorge/issues/8)), `AGENTS.md` truncation ([#7](https://github.com/georgewangyu/JarvisAIGeorge/issues/7)) |
| **Your local config** | Unknown or obsolete keys in your user config, a launcher or profile override, a deprecated flag | You | Edit or remove the key in your own config. Jarvis never edits it |
| **A third-party plugin** | Metadata that another plugin ships and the tool ignores or limits (prompt length, icon, description) | That plugin's author | Report it to them, or disable that plugin if it bothers you |
| **An optional service** | An MCP server that is unreachable or needs sign-in, a browser bridge missing its inputs, a title or summary helper that failed | You, only if you need that service | Start or sign in to it when you want it. Jarvis works without it |
| **Fleet readiness** | Lines Jarvis itself prints: `JARVIS_FIRST_RUN:`, `JARVIS_SETUP: MISSING ...`, bootstrap `MISSING:`, `NEEDS_GH_AUTH`, `SKILL_CATALOG_INCOMPLETE:` | Jarvis asks you | Answer Jarvis's setup questions. Each has a troubleshooting entry in [`install.md`](install.md) |

A skill-list overflow ("skills context budget exceeded", descriptions removed, skills omitted) is a worker-readiness signal, owned by fleet readiness (`SKILL_CATALOG_INCOMPLETE:`). It reflects the whole installed catalog, not this plugin alone; see [`jarvis-plugins.md`](jarvis-plugins.md) "Skill listing budget".

## Examples

These are illustrative lines (synthetic, not copied from a real session), with the owner and action for each.

| Example warning | Owner | Action |
|---|---|---|
| `ignoring unknown config key "model_reasoning_summary_format"` | Your local config | Remove or rename the key in your user config |
| `MCP server "local-notes" failed to connect: connection refused (127.0.0.1:8765)` | Optional service | Start that server if you use it; otherwise ignore or remove it from your MCP config |
| `MCP server "team-wiki" requires authentication` | Optional service | Sign in to it when you need it; Jarvis never signs in for you |
| `browser bridge disabled: BRIDGE_TOKEN and BRIDGE_PORT not set` | Optional service | Set those inputs only if you use the browser bridge |
| `launcher override requires embedded mode; falling back` | Your local config | Check the launcher or profile override you set; remove it if you did not mean it |
| `failed to generate session title: transport error` | Optional service (the tool's own helper) | Nothing to do; the session works without a title |
| `plugin "some-plugin": prompt and icon metadata ignored (over limit)` | A third-party plugin | Tell its author, or disable the plugin |
| `clamping SessionEnd hook timeout to 3s` for `jarvis-ai-george` | Jarvis | Fixed in 0.3.3 ([#8](https://github.com/georgewangyu/JarvisAIGeorge/issues/8)); update the plugin |
| `JARVIS_SETUP: MISSING tools gh-axi no-mistakes` | Fleet readiness | Approve the installs Jarvis offers |

## Rules for agents

- Never log or paste credentials, tokens or sign-in URLs from a warning into chat, an issue or a report.
- Never restart services, sign in, or edit the user's config to clear a warning. Report the owner and the action, and act only on what this project owns.
- Treat an optional-service warning as a capability gap, not a fleet failure: keep working and mention it once if the task needs that service.
