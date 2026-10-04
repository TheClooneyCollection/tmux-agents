# tmux-agents: design notes

How the `tmux-*` scripts work, why they work that way, and the traps found while building them. For usage, see [README.md](README.md) and [docs/guide.md](docs/guide.md).

## Goals

- Agents (Claude, Codex, anything) in ordinary tmux panes can message each other.
- The user can watch every pane and answer any agent in its own UI. Sub agents start in auto mode (Claude's auto permission mode, Codex's auto review), so they rarely ask; when they do, or need the user, they're flagged.
- Any number of panes, connected ad hoc. There is no fixed layout or session launcher.
- No server to run. Live state is on the panes; the only files are what must outlive a pane (session records for reopening, the message queue) and one background process that animates the chip, restarted on demand.
- Sub agents are real agents in their own panes, hidden by default but one keystroke away, so their full history stays readable.

## Architecture

Live state lives in tmux user options on the panes themselves: a pane's name, its links to other panes, and, for sub agents, their parent and state. Closing a pane cleans up its links. Two things must outlive a pane and are files: session records (`~/.local/state/tmux-agents/<server>/sessions/`), so a closed sub agent can be reopened, and the message queue (`/tmp/tmux-agents-<uid>/queue/<server>/`), so no message is dropped while its receiver is busy or gone. Links are explicit and symmetric, so the user always knows who can reach whom.

A message is text pasted into the receiver's pane and submitted, exactly as if the user had typed it. The sender ends its turn; the answer arrives later as a new prompt in its own pane. Every message carries the sender's and receiver's names and its own reply instructions, so an agent that never loaded the skill can still answer.

Sub agents are ordinary agents started by `tmux-spawn`, in hidden windows of an `agents-<project>` session by default or in a visible split (`--split`), linked to their owner: whoever spawned them, or the agent named with `--for`. The `prefix + a` switcher lists and opens them, and a second status line (the chip) shows what each one is doing, fed by reports and hooks rather than screen scraping.

## Scripts

| File | Role |
| --- | --- |
| `lib.sh` | Shared helpers, sourced by the others: pane lookup, naming, peers, labels. Not executable, so it never shows up as a command even though `bin/` is on `PATH`. |
| `tmux-connect` | Picker, naming form, linking, popup mode, and agent mode (`--from`). |
| `tmux-disconnect` | Removes links. |
| `tmux-peers` | Lists connections. `--refresh` rebuilds labels (used by hooks). |
| `tmux-ask` | Sends a message (request, reply or notice), or queues it while the user is busy in that pane; never drops it (bounces to the sender if the receiver is gone). `--pending` / `--retry` for the backlog. |
| `tmux-peek` | Reads a peer's screen (`capture-pane -J`). |
| `tmux-spawn` | Starts a connected sub agent in a hidden window or a visible split, for the caller or for another agent (`--for`); `--resume` reopens a closed one. `--run` is its in-pane half. |
| `tmux-agent-report` | Sub agent progress, permission and turn-end reports for the chip. |
| `tmux-agents` | fzf switcher (`prefix + a`). `--list`, `--view`, `--chip` and `--alert` are among its helper modes. |
| `tmux-dismiss` | Closes an agent and its sub agents (the whole subtree; `--keep-children` for just the one); agents may close their descendants. |

## Topics

- [State and protocol](docs/design/state-and-protocol.md): pane options, links, naming, connecting, message format and delivery, long messages.
- [Sub agents](docs/design/sub-agents.md): spawning, the switcher, done state and cleanup, closing, the status chip, alerts.
- [Environment](docs/design/environment.md): macOS bash 3.2, Codex's sandbox and shared daemon, permissions, install layout.
- [Pitfalls and testing](docs/design/pitfalls-and-testing.md): traps found while building, how to test without touching the user's server, known limitations.
- [Performance](docs/performance.md): what made it slow, the measurements, and how shell startup affects popups and spawns.
- [Product decisions](docs/decisions/README.md): what the user decided about behaviour, and why, one per file.
