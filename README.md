# tmux-agents

English | [简体中文](README.zh-CN.md)

**Your sub agents shouldn't disappear when the task ends.** Built-in sub agents run out of sight. You get a summary at the end, and the work behind it is gone.

tmux-agents runs each Claude or Codex sub agent in its own tmux window instead. Watch its work in a live preview, or switch in to give direction.

Agents send tasks and updates to each other. Their panes stay until you close them, and their conversations remain afterward: in Codex you can find them in `codex resume`, in Claude in `claude --resume`.

See the work. Keep the history. Pick it up again.

- **Real sessions, not black boxes.** Every sub agent is a full Claude or Codex session with its whole history on screen. Approve a prompt, ask a follow-up, or correct it mid-task.
- **One glance to know who needs you.** A line above your status bar shows each sub agent working, done, waiting for permission or waiting for you.
- **Agents that talk to each other.** Tell Claude "connect codex and have it review this diff", and the reply comes back to Claude as a new message.
- **Stays out of your way.** Sub agents live in a hidden session per project. Nothing is added to your layout, and a message never lands while you're typing in that pane.
- **Just tmux and bash.** No server to run: the state lives on the tmux panes.

## Screenshots

<p align="center">
  <img src="docs/message-request.png" width="49%" alt="A request from Claude arriving in Codex's pane">
  <img src="docs/message-reply.png" width="49%" alt="Codex's reply arriving back in Claude's pane">
</p>

<p align="center">Claude asks Codex for a review, and the reply comes back as a new message.</p>

<p align="center">
  <img src="docs/agent-list.png" width="49%" alt="The agent list: sub agents with their status and parent, and a live preview of the selected one">
  <img src="docs/popup.png" width="49%" alt="A hidden Codex sub agent opened in a popup from the list">
</p>

<p align="center"><code>prefix + a</code> lists your sub agents with a live preview. Open one in a popup to answer it or give direction.</p>

Status bar: a line above your status bar keeps count, and turns red or amber when an agent needs you:

```
      ⠹ auth-review: reading src/auth.ts  │  api ⠹ 2 ✓ 1 · blog ⠹ 1
```

Design notes, protocol details and known pitfalls: [DESIGN.md](DESIGN.md).

## Install

The easy way: ask Claude Code or Codex to do it.

> Install tmux-agents for me by following https://github.com/TheClooneyCollection/tmux-agents/blob/main/skills/tmux-agents-setup/SKILL.md

It checks what you have, runs the installer, shows you each config change before making it, and then walks you through a quick start. Later, say "tmux-agents quick start" to any agent to take the tour again.

For user-level skill installation, use the [skills CLI](https://skills.sh) below or `./install.sh` in the manual steps. After using the CLI, tell your agent "set up tmux-agents" to install the commands and configure tmux:

```sh
npx skills add TheClooneyCollection/tmux-agents -g
```

To list the available skills without installing them, add `--list`. This previews discovery only; `./install.sh --dry-run` previews the checkout installer.

### By hand

Needs tmux 3.2+ and bash. `fzf` is optional (nicer pickers and the live agent list).

```sh
git clone https://github.com/TheClooneyCollection/tmux-agents.git
cd tmux-agents
./install.sh            # --dry-run to see what it does first
```

`install.sh`:

- links the `tmux-*` commands into `~/.local/bin` (`BIN_DIR` to change)
- links the `tmux-agents`, `tmux-agents-setup`, `tmux-agents-perf` and `agent-chain` skills into `~/.claude/skills/` and your Codex home
- copies the Codex rules (Codex skips symlinked `.rules` files)
- preserves real files and directories at link destinations unless `--force` backs them up as `DEST.bak.YYYYmmddHHMMSS` before linking

Then add these to your own config (`install.sh` prints them with your paths):

| | |
| --- | --- |
| **tmux** | `source-file ~/path/to/tmux-agents/tmux/tmux-agents.conf` in `~/.tmux.conf`, then reload |
| **PATH** | `~/.local/bin` |
| **Claude** | the `allow` rules from [`integrations/claude/settings.json`](integrations/claude/settings.json), into `~/.claude/settings.json` |
| **Codex** | the wrapper: [`integrations/fish/functions/`](integrations/fish/functions) or [`integrations/sh/codex.sh`](integrations/sh/codex.sh) |

<details>
<summary>What each one is for</summary>

- **tmux:** `prefix + a` (agents), `prefix + A` (connect), the sub agent chip, and hooks for border refresh, bell alerts and queued messages. If you linked the commands somewhere other than `~/.local/bin`, put `%hidden TMUX_AGENTS_BIN="/that/dir"` before the `source-file` line.
- **Claude:** agents can message, peek, spawn, report, rename themselves or descendants, and close their own sub agents without prompting. `tmux-connect` (without `--from`), `tmux-disconnect`, plain `tmux-dismiss` and plain `tmux-rename` stay yours and still prompt.
- **Codex:** Codex runs commands in a shared daemon whose `$TMUX_PANE` may be another pane, so the wrapper pins each Codex to its own pane (see DESIGN.md). Copy the fish functions into `~/.config/fish/functions/`, or `source` the sh file from `~/.bashrc` / `~/.zshrc`.
- **Optional:** tell your agents to use `tmux-spawn` for every sub agent, in `CLAUDE.md` / `AGENTS.md`. The skill explains how.

</details>

Update the actual installed checkout: on a branch, use `git pull --ff-only`; for a detached/tag install, use `git fetch --tags` and `git checkout <new-tag>` with your chosen tag. Then re-run `./install.sh` there to refresh rules and rebuild skill links, including links to the old skill folders.

Using more than one Codex account? See [the guide](docs/guide.md#more-than-one-codex-account).

### If popups feel slow

tmux-agents is fast (a list build takes about 0.1s), but tmux runs every popup and every new agent's window through your `default-shell`, which reads its config first. Check:

```sh
tmux show -gv default-shell
time fish -c true        # use your shell; compare with --no-config / --norc / -f
```

Hundreds of milliseconds there are paid on every `prefix + a` (the list itself draws its prompt first and loads the rows right after). See [docs/performance.md](docs/performance.md) for the fix, or ask your agent to "find out why tmux-agents is slow" (the `tmux-agents-perf` skill).

## Configuration

Set user preferences in `tmux.conf`, or change them live with `tmux set -g`. Environment overrides win over options, then the defaults below apply. For given names, `--exact` takes priority over both. Use the full name printed by `tmux-spawn` or `tmux-rename`.

```tmux
set -g @tmux_agents_name_format exact
```

| Option | Environment override | Default | What it does |
| --- | --- | --- | --- |
| `@tmux_agents_name_format` | `TMUX_AGENTS_NAME_FORMAT` | `prefixed` | Given-name format: `exact` or `prefixed` |
| `@tmux_agents_max_depth` | `TMUX_AGENTS_MAX_DEPTH` | `2` | Maximum sub agent depth |
| `@tmux_agents_codex_homes` | `TMUX_AGENTS_CODEX_HOMES` | `none` | Extra accounts as `PROFILE=CODEX_HOME` pairs |
| `@tmux_agents_session_prefix` | `TMUX_AGENTS_PREFIX` | `agents` | Hidden session name prefix |
| `@tmux_agents_resume_days` | `TMUX_AGENTS_RESUME_DAYS` | `7` | Days to retain closed agents in the list |
| `@tmux_agents_preview_secs` | `TMUX_AGENTS_PREVIEW_SECS` | `0.5` | Seconds between preview refreshes |
| `@tmux_agents_blink_secs` | `TMUX_AGENTS_BLINK_SECS` | `60` | Seconds before attention starts blinking |
| `@tmux_agents_chip_fps` | none | `10` | Chip animation frames per second |
| `@tmux_agents_ask_idle_secs` | `TMUX_ASK_IDLE_SECS` | `8` | Seconds without keys before delivery |
| `@tmux_agents_ask_copy_idle_secs` | `TMUX_ASK_COPY_IDLE_SECS` | `300` | Exit idle copy mode after this many seconds; `0` disables |
| `@tmux_agents_ask_queue_secs` | `TMUX_ASK_QUEUE_SECS` | `1800` | Seconds before showing message waiting; messages stay queued |
| `@tmux_agents_ask_max_lines` | `TMUX_ASK_MAX_LINES` | `60` | Save longer messages to a file |
| `@tmux_agents_ask_enter_delay` | `TMUX_ASK_ENTER_DELAY` | `0.5` | Seconds between paste and Enter |
| `@tmux_agents_connect_highlight` | `TMUX_CONNECT_HIGHLIGHT` | `bg=colour24` | Style of the highlighted connection target |

`TMUX_AGENTS_CODEX_HOMES` also keeps its tmux global-environment fallback when neither a local override nor the option is set. Settings are read once per command; restart an existing picker or chip daemon to apply changes to its cached settings. Set overrides after sourcing `tmux-agents.conf`, which installs the chip FPS default. Internal pane state and test hooks are not user settings.

## Quick start

1. Split a tmux window. Start `claude` in one pane and `codex` in the other.
2. Tell Claude: "use tmux-agents to connect to the codex pane and have it review this diff". The request lands in Codex's pane, and the reply comes back to Claude.
3. Tell Claude: "spawn a sub agent to add tests for the parser". It runs in a hidden window, and a line above your status bar shows how it's doing.
4. Press `prefix + a` to watch it. Enter opens it in a popup, `prefix + d` goes back.
5. Tell Claude: "start the chain". It becomes the main agent you talk to, with a secondary that coordinates and a Codex worker that implements, side by side in your window (the `agent-chain` skill).

Or let your agent show you: say "tmux-agents quick start".

## Keys

| Key | |
| --- | --- |
| `prefix + a` | The agent list, with a live preview |
| `prefix + A` | Connect this pane to another one (`ctrl-a`: any window) |
| `prefix + d` | In a popup: back to the list. In the list: close it |

The list opens on this window and its descendants, with sub agents and members needing you pinned from every window.

In the list: `enter` open · `ctrl-o` jump there · `ctrl-x` dismiss · `ctrl-d` close all finished · `ctrl-a` all panes / sub agents · `ctrl-t` this window / all windows

Long-lived team members use `tmux-spawn --member`. They stay out of the default sub-agent list, ordinary chip counts and `ctrl-d` / `--done` cleanup. `ctrl-a` shows them as `member of <owner>`; attention still pins them. Explicit dismissal still closes their subtree, and reopening preserves membership.

Closed sub agents and members stay in a `closed` section at the bottom for 7 days: `enter` reopens one with its whole conversation. Or ask its parent to reopen it.

Status: `⠹` working · `○` idle (no task yet) · `✓` done · `⚠` waiting for permission (red) · `◆` needs you (amber) · `✉` message waiting for you to stop typing or scrolling · `✗` exited

## Commands

Agents run these for you; each takes `--help`.

| Command | |
| --- | --- |
| `tmux-connect` | Name this pane and link it to another |
| `tmux-rename` | Change an agent's label while keeping its identity, history and links |
| `tmux-ask` | Send a message to a connected agent |
| `tmux-spawn` | Start a sub agent, or a long-lived `--member`, hidden or with `--split` |
| `tmux-agents` | The agent list (`prefix + a`) |
| `tmux-peers`, `tmux-peek` | Show connections; read another pane |
| `tmux-dismiss`, `tmux-disconnect` | Close a sub agent; unlink panes |
| `tmux-agent-report` | Report progress for the status line |

Live commands still use names; IDs are only needed to select an ambiguous saved conversation. Names are labels: reusing a closed agent's name keeps both histories. The list distinguishes same-named closed agents by time, parent and project; IDs stay out of its rows but can appear in the closed preview. For scripts and agents, `tmux-peers --ids` and `tmux-spawn --list-closed` expose IDs; `--resume-id ID` reopens one exact conversation when `--resume NAME` is ambiguous.

How messages flow, sub agent details, settings and how it works: [the guide](docs/guide.md).

## License

MIT, see [LICENSE](LICENSE).
