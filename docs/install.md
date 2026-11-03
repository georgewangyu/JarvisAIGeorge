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
Using Codex instead: the same three lines with `codex` in place of `claude`. See [Using Codex](#using-codex).

## What happens on first start

| # | Prompt | Who asks | What to answer |
|---|---|---|---|
| 1 | Theme, security notes | Claude Code, first run on this machine only | Your choice, then Enter |
| 2 | Trust this folder (lists the one pre-approved command, `bin/jarvis-setup.sh`) | Claude Code | Yes. Trust also adds the Jarvis marketplace and loads the core plugin, with no extra prompt |
| 3 | Use cmux tabs for workers? | Jarvis | Yes for a Jarvis tab plus a Workers group with a live board; no for tmux or auto |
| 4 | What should Jarvis call you? (default: no special address) | Jarvis | A name, or nothing for plain "you". Stored in the home's gitignored `config/user-address` |
| 5 | Add a launch shortcut? Name (default `jarvis`) and the folder it starts in | Jarvis | Yes writes a marked alias block to `~/.zshrc` and `~/.bashrc`; see "Launch shortcut" |
| 6 | Which extensions to install (coding extension recommended) | Jarvis | Yes installs `george-coding-agent` (coding worker, read-only reviewer, planning, spec and review skills) |
| 7 | Which missing tools to install, one command each | Jarvis | Approve each. Jarvis installs nothing without a yes |
| 8 | cmux socket access, only if the check fails | Jarvis | The one manual step below |

On later starts Jarvis is quiet unless something needs a call (a missing piece, an update).

The manager is named JarvisAIGeorge in Claude Code and Codex alike. To rename it, run `bin/jarvis-setup.sh name <name>` (stored in the gitignored `config/manager-name`; `name default` undoes it) and restart. The cmux manager tab takes the same name.

## Requirements

- Claude Code or Codex, logged in.
- Git and the GitHub CLI (`gh auth login` done).
- macOS or Linux. Homebrew on macOS for the optional tools (`jq`, cmux).

## The steps in detail

1. **Clone and start.** Run the three lines above in a terminal (in cmux if you want cmux tabs).
2. **Trust the folder.** Claude Code asks once. The folder's settings register the `jarvis-ai-george` marketplace, enable the core and coding plugins, turn on the setup check, and pre-approve only `bin/jarvis-setup.sh`.
3. **First-time setup.** A session start hook runs `bin/jarvis-setup.sh detect` (fast, read-only, no network, no installs). When anything is missing it tells Jarvis to run setup now. Jarvis then:
   1. runs `bin/jarvis-setup.sh status` and tells you what is missing (status also shows, on separate lines, the saved backend choice, the terminal you are in, and where new workers will spawn, since a saved choice wins over the terminal);
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
- [ ] cmux only: the manager tab is renamed **JarvisAIGeorge**, pinned and colored, and a **JarvisAIGeorge: Workers** group with a board appears on the first dispatch.
- [ ] Dispatch a tiny task (for example, a `hello.sh` in a throwaway repo under `projects/`): a worker tab appears, its pill goes working then done, Jarvis reports the result, and the tab closes after the change lands.
- [ ] Ask Jarvis to post a message or update a ticket through an MCP tool: the write guard blocks it and Jarvis offers to dispatch a worker instead.

## Launch shortcut

Start Jarvis from your own workspace folder, so that folder's `CLAUDE.md` (and the `AGENTS.md` it imports) or `AGENTS.md` chain loads as usual, while the clone stays the engine.

First-run setup offers the shortcut. On your yes it writes this block to `~/.zshrc` and `~/.bashrc` (marked, and replaced in place if you run it again):

```sh
# >>> jarvis-launch shortcut: jarvis (added by bin/jarvis-setup.sh; undo: ~/jarvis/bin/jarvis-setup.sh shortcut remove --name jarvis) >>>
alias jarvis='cd ~/work && ~/jarvis/bin/jarvis-launch'
# <<< jarvis-launch shortcut: jarvis <<<
```

By hand: `~/jarvis/bin/jarvis-setup.sh shortcut add --name jarvis --folder ~/work`. Undo: `~/jarvis/bin/jarvis-setup.sh shortcut remove --name jarvis`.
Nothing edits a shell file without your yes.

What `jarvis-launch` does:

- Inside the clone it is plain `claude`, so everything above applies unchanged.
- Anywhere else it keeps your folder as the working directory and starts `claude --agent jarvis-ai-george:jarvis-ai-george` (the core plugin's manager). It sets `JARVIS_HOME` and `FM_HOME` to the clone, and passes the clone's hooks with `--settings`: session start, setup check, guards and the MCP write guard, all run from the clone.
- Jarvis then reads `$JARVIS_HOME/AGENTS.md` as the home contract before any fleet action. Your folder's instructions decide how it talks and works; the home contract decides fleet safety.
- If another session already holds the home's lock, the new one stays read-only. Starting Jarvis never takes over a running fleet.
- Codex: `jarvis-launch --codex` starts `codex` in your folder with a first prompt that loads `$role-jarvis` and the home contract. Verify this on your own machine.

Loading the `role-jarvis` skill by itself, outside a home and without the launcher, gives you the manager without a fleet: it plans and routes, but runs no hooks, takes no lock and starts no workers.

Checks:

- [ ] In your folder, `jarvis` starts a session whose first answer knows your folder's instructions and says it is Jarvis.
- [ ] The setup line or update check appears, and `echo $JARVIS_HOME` in that session prints the clone path.

## Updates

At session start Jarvis runs `bin/jarvis-setup.sh update-check` (bounded, quiet when current):

- the home is behind origin: Jarvis offers `/updatefirstmate` (a guarded fast-forward);
- plugin auto-update was never chosen: Jarvis asks once and records the answer with `bin/jarvis-setup.sh plugin-autoupdate on|off` (Claude Code then updates the marketplace and its plugins at startup).

Nothing updates without your yes. Turn the check off with `echo off > config/update-check`.

An update never breaks a session that is already running:

- **Home hooks.** Every hook entry in `.claude/settings.json`, `.codex/hooks.json` and the `jarvis-launch` settings calls `bin/hook <script>`. At session start it pins the session to a snapshot of the home's hook code at the current commit (`state/hook-releases/<commit>/`), and every later hook of that session runs that snapshot with the live home's state and config. After a `git pull`, running sessions keep their code; a new session pins the new commit. Snapshots older than 3 days go once no live session uses them (`JARVIS_HOOK_KEEP_DAYS`).
- **Plugins.** Every plugin change ships under a new version, and Claude Code keeps the old version folder for sessions still using it (`docs/jarvis-plugins.md`).
- **Notice.** An old session shows "Jarvis was updated. Restart to load it." once, at its next prompt. Restart (or `--resume`) to load the update; a `/compact` keeps the old code. Turn it off with `JARVIS_UPDATE_NOTICE=off`.

## Manager write guard

In the home, the manager runs a PreToolUse hook (`bin/jarvis-manager-write-guard.sh`) that blocks MCP tools whose name or action looks like a write (create, update, delete, send, post, comment, deploy, publish, merge, resolve, write, edit, remove) and tells Jarvis to dispatch a worker.
Reads and searches pass. Edit `config/manager-write-words` (one word per line) to change the list; an empty file turns the guard off.
Workers do not run it.

## Using Codex

```sh
gh auth login
git clone https://github.com/georgewangyu/JarvisAIGeorge ~/jarvis
cd ~/jarvis && codex
```

Use a recent Codex CLI: `codex plugin add` needs 0.122 or later, and FirstMate's Codex manager checks were verified on 0.142.
Log in with the account you want this machine to use (`codex login`).

### First start with Codex

| # | Prompt | Who asks | What to answer |
|---|---|---|---|
| 1 | Do you trust the contents of this directory? | Codex | Yes. It loads `AGENTS.md` and the folder's `.codex/` hooks |
| 2 | Hooks need review (new or changed hooks) | Codex | Review and trust them (or `/hooks` later). They run session start, the setup check, the write guard and the turn-end guard. Declined: Jarvis still runs the setup check itself, but there is no write guard |
| 3 | Use cmux tabs, which extensions, which tools | Jarvis | The same one form as on Claude |
| 4 | Approve a command (network or writes outside the folder) | Codex | Approve `codex plugin marketplace add`, `codex plugin add` and each tool install you agreed to |
| 5 | Restart Codex here | Jarvis | `/quit`, then `codex` again, so the new plugin skills load |

### What differs from Claude Code

- **Jarvis role.** Codex has no agent files. `AGENTS.md` tells the session that it is Jarvis and to read `role-jarvis` and the extension catalog at start.
- **Setup check.** Codex runs `bin/jarvis-setup.sh detect` from `.codex/hooks.json` once its hooks are trusted; without them Jarvis runs it itself. `jarvis-setup.sh` detects Codex and uses `codex plugin marketplace add georgewangyu/JarvisAIGeorge` and `codex plugin add <plugin>@jarvis-ai-george`.
- **Plugins.** Nothing loads on folder trust: Jarvis offers the core plugin and the coding extension, and installs only after your yes. Codex keeps plugins in `~/.codex/plugins/cache/`; an extension installed from its own marketplace (`@george-coding-agent`) counts too. Update with `codex plugin marketplace upgrade jarvis-ai-george`; there is no auto-update setting to choose.
- **Workers.** A Codex worker takes its role from a skill named on its brief's first line (`$role-coding`, `$role-reviewer`); there is no `--agent`. Worker launches turn Codex hooks off, so a worker never stops on the hook review.
- **Reviewer read-only.** Codex cannot enforce the reviewer's read-only tools. The `role-reviewer` skill says so and the reviewer follows it by instruction. A fleet reviewer keeps the normal sandbox because it must write its status and report files; a standalone review (`codex exec --sandbox read-only 'Load $role-reviewer first. ...'`) is enforced, and the coding role's review loop uses that form.
- **Write guard.** The same guard runs as a Codex PreToolUse hook on `mcp__` tools in the manager session. It needs the hooks trusted (prompt 2).
- **Waiting.** Jarvis waits on workers in short foreground checkpoints (about 3 minutes), so it can still answer you between them.
- **cmux.** The board and tab colors cover Codex workers by polling. There is no sidebar pill for a Codex worker (it runs no hooks); the pill is Claude only.

### Codex troubleshooting

- **Plain Codex instead of Jarvis.** Check you started `codex` in the clone, then say "Read the Jarvis section of AGENTS.md and act as Jarvis."
- **No setup line at start.** The hooks were not trusted. Run `/hooks` and trust them, or ask Jarvis to run `bin/jarvis-setup.sh status`.
- **`codex plugin` is unknown.** Upgrade the Codex CLI (older releases used `codex marketplace add` and had no `codex plugin add`).
- **Marketplace add or plugin add fails.** It needs network: approve the command when Codex asks, and check `gh auth status`. By hand: `codex plugin marketplace add georgewangyu/JarvisAIGeorge`, then `codex plugin add jarvis-ai-george@jarvis-ai-george` and `codex plugin add george-coding-agent@jarvis-ai-george`.
- **Skills not found after install.** Start a new Codex session in the folder.
- **Wrong harness detected.** `bin/jarvis-setup.sh harness` prints the tool it sees; force it with `JARVIS_HARNESS=codex bin/jarvis-setup.sh status`.

### Reading a Codex warning panel in cmux

Codex shows a warning count with "F2 to view". The panel works; it just needs a real F2 key press.

1. Click into that Codex tab and press **F2** on the keyboard yourself. Close the panel the way it says (usually Esc) before typing again.
2. To let Jarvis read it without typing into the session, keep the panel open and ask Jarvis to read the screen: `cmux read-screen --workspace <that tab> --lines 80` only reads text and sends no input.
3. Do not automate F2. `cmux send-key` has no F2 (cmux 0.64.25 and 0.65.2 answer `invalid_params: Unknown key`). Never send raw escape bytes (for example with `cmux send`) into a live Codex composer: they arrive as typed input and can interrupt or edit the prompt in progress.
4. If you only need the warnings as text, start a separate Codex session in a scratch tab for diagnostics rather than touching a working one, and keep any automation on your own tab.

Verify on a personal laptop: the panel opens on F2 and closes on Esc for your Codex version.

### Codex test script (run on the laptop, report back)

Run in a throwaway cmux workspace, from a fresh clone. Report each step as pass or fail with the exact output or error.

1. `codex --version` and `bin/jarvis-setup.sh harness` (from inside the Codex session, through Jarvis): expect a version of 0.122 or later and `codex`.
2. Start `codex` in `~/jarvis`. Record every prompt in order, with its wording.
3. After trusting the hooks, does the first reply mention setup (the `JARVIS_FIRST_RUN:` line) without being asked? Does Jarvis say it is Jarvis and list the coding extension as not installed?
4. Answer the form: cmux yes, coding extension yes, tools as you like. Expect `codex plugin marketplace add ...` and `codex plugin add jarvis-ai-george@jarvis-ai-george` and `codex plugin add george-coding-agent@jarvis-ai-george`, each after your yes.
5. `/quit`, `codex` again. `codex plugin list` shows both plugins `installed, enabled`. `bin/jarvis-setup.sh status` prints only `ok:` lines (tools may stay missing if declined).
6. Ask "What agents can you dispatch?": expect `coding` and `reviewer`, both installed, with the Codex launch shape (`$role-coding` in the brief).
7. Dispatch a tiny task in a throwaway repo under `projects/` (for example a `hello.sh`). Expect a worker tab under **JarvisAIGeorge: Workers**, the board coloring it, no pill, and a result relayed by Jarvis.
8. Ask for a review of that change. Expect a reviewer worker that loads `$role-reviewer` and edits nothing (`git status` clean in that repo afterwards).
9. Ask Jarvis to post a message or update a ticket through an MCP tool, if one is configured. Expect the write guard to block it.
10. In the coding worker or a plain `codex` in a repo: `codex exec --sandbox read-only 'Load $role-reviewer first. Review the last commit.'` returns findings and changes nothing.

Report: the prompt list from step 2, pass or fail per step, and any error text.

## Without the clone

The plugins also install on their own:

- Coding agent only: `claude plugin marketplace add georgewangyu/GeorgeCodingAgent`, `claude plugin install george-coding-agent@george-coding-agent`, `claude --agent george-coding-agent:coding`.
  Codex: `codex plugin marketplace add georgewangyu/GeorgeCodingAgent`, `codex plugin add george-coding-agent@george-coding-agent`, then start with "Load `$role-coding` first".
- Manager file anywhere: copy `plugins/jarvis-ai-george/standalone/jarvis-ai-george.md` to `~/.claude/agents/`. Without a home it has no fleet tooling, setup check or write guard.

[`jarvis-plugins.md`](jarvis-plugins.md) has the per-tool details.

## Troubleshooting

Several unrelated warnings at startup? Sort them by owner first: [`startup-warnings.md`](startup-warnings.md).


### Too many skills, or a skill is missing from the list

Claude Code warns when the installed skills do not fit its skill listing, and Codex shows a warning panel that it removed descriptions or omitted skills.
Jarvis keeps its own share small: each plugin lists only a router and a few skills, and every other skill is one hop away through the router (see [`jarvis-plugins.md`](jarvis-plugins.md) "Skill listing budget").

- Find a skill Jarvis does not list: load `extension-catalog` (core) or `george-coding-agent-skills` (coding), which name every skill and its file.
- Free budget: disable or uninstall plugins you do not use with `claude plugin disable <plugin>` or Codex's plugin commands. Jarvis never removes your other skills.
- Codex workers: briefs name their skills explicitly (`$role-coding`, `$test-driven-development`), and the spawn prints `SKILL_CATALOG_INCOMPLETE:` when the worker's screen shows the warning.

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
From any other folder use the launch shortcut (`jarvis-launch`); plain `claude` there is not Jarvis.
`jarvis-launch` says `claude is not on PATH`, or the plugin agent is missing: install the core plugin (`claude plugin install jarvis-ai-george@jarvis-ai-george`) and retry.
`claude` in a project under `projects/` starts the default agent on purpose, so workers there are not managers.
