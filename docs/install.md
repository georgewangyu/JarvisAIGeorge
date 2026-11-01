# Install JarvisAIGeorge

Three lines, then answer Jarvis's questions in chat.
The clone is the install: it carries the manager agent, the plugin marketplace, the setup check and the fleet tooling.

```sh
gh auth login
git clone https://github.com/georgewangyu/JarvisAIGeorge ~/jarvis
cd ~/jarvis && claude
```

Plain `claude` in the folder starts Jarvis (the repo's `.claude/settings.json` sets `"agent": "jarvis-ai-george"`).
`claude --agent jarvis-ai-george` does the same.

## What happens on first start

| # | Prompt | Who asks | What to answer |
|---|---|---|---|
| 1 | Theme, security notes | Claude Code, first run on this machine only | Your choice, then Enter |
| 2 | Trust this folder (lists the one pre-approved command, `bin/jarvis-setup.sh`) | Claude Code | Yes. Trust also adds the Jarvis marketplace and loads the core plugin, with no extra prompt |
| 3 | Use cmux tabs for workers? | Jarvis | Yes for a Jarvis tab plus a Workers group with a live board; no for tmux or auto |
| 4 | Which extensions to install (coding extension recommended) | Jarvis | Yes installs `george-coding-agent` (coding worker, read-only reviewer, planning, spec and review skills) |
| 5 | Which missing tools to install, one command each | Jarvis | Approve each. Jarvis installs nothing without a yes |
| 6 | cmux socket access, only if the check fails | Jarvis | The one manual step below |

On later starts Jarvis is quiet unless something needs a call (a missing piece, an update).

## Requirements

- Claude Code, logged in.
- Git and the GitHub CLI (`gh auth login` done).
- macOS or Linux. Homebrew on macOS for the optional tools (`jq`, cmux).

## The steps in detail

1. **Clone and start.** Run the three lines above in a terminal (in cmux if you want cmux tabs).
2. **Trust the folder.** Claude Code asks once. The folder's settings register the `jarvis-ai-george` marketplace, enable the core and coding plugins, turn on the setup check, and pre-approve only `bin/jarvis-setup.sh`.
3. **First-time setup.** A session start hook runs `bin/jarvis-setup.sh detect` (fast, read-only, no network, no installs). When anything is missing it tells Jarvis to run setup now. Jarvis then:
   1. runs `bin/jarvis-setup.sh status` and tells you what is missing;
   2. asks about cmux tabs and records the answer (`config/backend`, and `config/cmux-layout` = `workers` for cmux);
   3. offers the known extensions, coding recommended, and on your yes runs `claude plugin install george-coding-agent@jarvis-ai-george` itself;
   4. lists each missing tool with its exact install command (the fleet toolchain: `gh-axi`, `no-mistakes`, `chrome-devtools-axi`, `quota-axi`, `tasks-axi`, and `jq` and cmux for cmux) and runs only what you approve;
   5. checks the cmux socket and, if needed, tells you the manual step;
   6. runs `status` again and says when setup is done.
4. **Use it.** Ask Jarvis for work. It plans with you, dispatches a worker per unit of work into its own visible tab, reviews with the read-only reviewer, and reports back.

## Checklist

- [ ] `claude` in `~/jarvis` shows `@jarvis-ai-george` in the header.
- [ ] `bin/jarvis-setup.sh status` prints only `ok:` lines.
- [ ] `claude plugin list` shows `jarvis-ai-george` and, if you chose it, `george-coding-agent`.
- [ ] Ask Jarvis "What agents can you dispatch?": it lists `george-coding-agent:coding` and `george-coding-agent:reviewer`, each marked installed or not.
- [ ] cmux only: the manager tab is renamed **Jarvis**, pinned and colored, and a **Jarvis: Workers** group with a board appears on the first dispatch.
- [ ] Dispatch a tiny task (for example, a `hello.sh` in a throwaway repo under `projects/`): a worker tab appears, its pill goes working then done, Jarvis reports the result, and the tab closes after the change lands.
- [ ] Ask Jarvis to post a message or update a ticket through an MCP tool: the write guard blocks it and Jarvis offers to dispatch a worker instead.

## Updates

At session start Jarvis runs `bin/jarvis-setup.sh update-check` (bounded, quiet when current):

- the home is behind origin: Jarvis offers `/updatefirstmate` (a guarded fast-forward);
- plugin auto-update was never chosen: Jarvis asks once and records the answer with `bin/jarvis-setup.sh plugin-autoupdate on|off` (Claude Code then updates the marketplace and its plugins at startup).

Nothing updates without your yes. Turn the check off with `echo off > config/update-check`.

## Manager write guard

In the home, the manager runs a PreToolUse hook (`bin/jarvis-manager-write-guard.sh`) that blocks MCP tools whose name or action looks like a write (create, update, delete, send, post, comment, deploy, publish, merge, resolve, write, edit, remove) and tells Jarvis to dispatch a worker.
Reads and searches pass. Edit `config/manager-write-words` (one word per line) to change the list; an empty file turns the guard off.
Workers do not run it.

## Without the clone

The plugins also install on their own:

- Coding agent only: `claude plugin marketplace add georgewangyu/GeorgeCodingAgent`, `claude plugin install george-coding-agent@george-coding-agent`, `claude --agent george-coding-agent:coding`.
- Manager file anywhere: copy `plugins/jarvis-ai-george/standalone/jarvis-ai-george.md` to `~/.claude/agents/`. Without a home it has no fleet tooling, setup check or write guard.

[`jarvis-plugins.md`](jarvis-plugins.md) has the per-tool details.

## Troubleshooting

### Plugins did not install

Symptom: `status` reports `MISSING plugins` or `MISSING extension choice`, or `claude plugin list` lacks a plugin.
Folder trust loads the core plugin, but the coding extension lives in its own repo and installs only through Jarvis's offer or by hand.

1. Ask Jarvis to run `bin/jarvis-setup.sh plugins` (core) or `bin/jarvis-setup.sh extensions george-coding-agent`.
2. By hand:
   ```sh
   claude plugin marketplace add georgewangyu/JarvisAIGeorge
   claude plugin install jarvis-ai-george@jarvis-ai-george
   claude plugin install george-coding-agent@jarvis-ai-george
   ```
3. Restart `claude` in the folder. If `marketplace add` fails, check `gh auth status` and network access to GitHub.
4. An update did not apply: plugins update by version. Run `claude plugin marketplace update jarvis-ai-george`, then `claude plugin update <plugin>@jarvis-ai-george`, then restart.

### Toolchain approval

Symptom: Jarvis will not dispatch workers, or `status` reports `MISSING tools`.
The fleet needs its toolchain before the first dispatch. Jarvis lists each tool with its install command and runs only the ones you approve.

- `npm install -g ...` needs Node.js (`brew install node`).
- `no-mistakes` installs from a script (`curl ... | sh`); read it first if you prefer.
- Declined everything? Ask Jarvis "finish setup" later, or run the commands from `status` yourself.
- Fresh tools not found: open a new terminal so `PATH` picks them up, then restart `claude`.

### cmux

Symptom: `MISSING cmux app`. Install with `brew install --cask cmux` (or from the cmux site), open it once, and start `claude` in a cmux tab.

### cmux socket mode

Symptom: `MISSING cmux socket access (denied)` or `(unauth)`, or `bin/jarvis-setup.sh cmux-check` fails.
cmux admits only processes it started unless you allow automation. This is a security setting, so Jarvis never changes it.

1. In cmux, open **Settings > Automation**.
2. Set **Socket Control Mode** to **Automation**.
3. Ask Jarvis to run `bin/jarvis-setup.sh cmux-check` (or run it yourself). It prints `ok: cmux socket` when done.

Password mode also works: put the password in `config/cmux-socket-password`. Avoid full open access. Prefer not to use cmux: `bin/jarvis-setup.sh backend tmux`.

### Folder trust declined

Claude Code exits. Run `claude` in the folder again and trust it; nothing was installed.

### Jarvis did not start (plain Claude instead)

Check that you started `claude` inside the clone (the `agent` setting is per folder), or use `claude --agent jarvis-ai-george`.
`claude` in a project under `projects/` starts the default agent on purpose, so workers there are not managers.
