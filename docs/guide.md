# tmux-agents guide

The operating details behind the [README's use cases](../README.md#common-use-cases). See [DESIGN.md](../DESIGN.md) for implementation and recovery notes.

Agent examples use `ME` and `PEER` as placeholders for actual full names. Agents always pass `--from ME`, since Codex's shared command process can otherwise identify the wrong pane.

## Dependencies

Requires tmux 3.2+ and bash; the agent list also needs fzf. Other commands work without fzf. See [installation](../README.md#install).

## Configuration

[Configuration](configuration.md) lists settings, defaults and environment overrides. The workflows below describe their effects.

## Starting agents

From a tmux shell:

```sh
tmux-agents start claude|codex|PROFILE [--name NAME [--exact]] [-- AGENT ARGS]
```

Choose one kind or configured Codex profile. The launcher names the pane, pins its identity and supplies turn tracking without editing global agent configuration. It keeps the agent's permission defaults. Arguments after `--` pass through unchanged, including resume arguments; top-level sessions cannot be reopened with `tmux-spawn --resume`.

Plain launches start idle. Incoming requests, progress reports or turn-start hooks start work; opaque agent arguments do not change the initial state. Agents without tracking show `-` and no worked time, but can still exchange messages. Codex shell wrappers pin identity only; prefer `start` for tracking.

Exiting saves work, clears agent state and returns to the shell. Reusing a named pane from its own terminal retains its name and connections; `--name` can rename it first. Invalid or taken names refuse without changing it. Another terminal cannot take over a named pane.

For another independent agent, split manually and run `start` there. For a connected helper, ask your agent to use `tmux-spawn --split`.

```sh
tmux-agents start chain [DIR] [--worker AGENT]
```

This opens a window named after DIR (default `$PWD`) and starts Claude working on “start the chain”. The [agent-chain skill](../skills/agent-chain/SKILL.md) creates its secondary and worker members. `--worker` selects an agent or profile; otherwise the skill uses your worker preference, defaulting to Codex.

## Connecting agents

Press `prefix + A` to connect existing panes. The popup previews this window's panes; `ctrl-a` switches to every window and remembers that choice. For unnamed panes, ↑/↓ selects name fields, typing edits and Enter accepts.

Or tell your agent “connect codex and ask it to review this diff”. It runs `tmux-connect --from ME codex`, then sends the request. Agent mode generates names without a form. `claude`/`codex` selects that type in this window; multiple matches require choosing an exact name or pane ID.

For another window, use `codex@stone-age` (project name or part), `claude@2` (window) or `claude@work:2` (session and window). `tmux-connect --from ME --list` lists candidates when the description is less specific. Cross-window connections send the other agent a notice.

Borders show `name ⇄ peers`. Links are one-to-one: A↔B and B↔C do not link A↔C. See [naming](#renaming-agents) for generated labels.

## How messages flow

Use `tmux-ask --from ME PEER "task"` for requests, `--reply` for answers and `--notice` for information needing no work or reply. Requests include reply instructions; the sender ends its turn and receives the answer later. A request saying “no reply needed” still starts work and makes the sender await a reply. Replies do not invite another reply.

Typing or scrolling delays delivery. `queued` means sent: do not resend. Leaving copy mode or becoming idle allows delivery in order; [configuration](configuration.md) controls idle, copy-mode and attention thresholds. Long waits show `✉`. If the receiver disappears, the message stays saved and the sender is notified; reopening a resumable receiver retries its messages.

Use `tmux-ask --pending` to inspect saved messages and `tmux-ask --retry --to PEER` to retry a live receiver, or omit `--to` for all available receivers. Unavailable destinations stay saved.

Message markers separate agent text from any user draft submitted with it. Agents treat text outside the markers as yours. Long reports use a summary plus file path; messages over the configured limit (default 60 lines) are saved automatically, with the first 15 lines and path delivered.

## Sub agents

Agents use `tmux-spawn` instead of built-in sub agents so each helper has a real pane and readable history:

```sh
tmux-spawn --from ME --name auth-review "Review src/auth.ts"
```

### Start a helper

Helpers inherit the caller's agent kind and Codex profile. They open hidden, one window each in a project session such as `agents-api`. Use the full name printed by spawn; [naming rules](#renaming-agents) apply.

| Spawn option | Effect |
| --- | --- |
| `--split PEER` | Place the helper visibly beside a named pane, using the caller's directory. |
| `--right` / `--below` | Choose direction with `--split`; right is the default. |
| `--size N%` | Choose its share with `--split`; default 50%. |

Splits keep the same ownership and depth rules and do not switch your focus. New and resumed helpers, including members, default to auto permissions. [Set `sub_auto` off](configuration.md) to use agent defaults; this setting does not affect top-level `start`.

### Watch and navigate

`prefix + a` opens the list with activity, parent, project and live preview. It starts with this window and its descendants, including hidden helpers. Attention from other windows appears first, longest wait first. The status chip shows global counts and highlights attention.

| Key | Action |
| --- | --- |
| `enter` | Open a hidden agent in a popup; jump to a visible pane. |
| `ctrl-o` | Jump full screen; `prefix + L` returns. |
| `prefix + d` | Leave an agent popup for the list, or close the list. |
| `ctrl-x` | Dismiss the selected agent and descendants. |
| `ctrl-d` | Confirm cleanup of done/exited subtrees, excluding members and unfinished work. |
| `ctrl-a` | Toggle helpers / every named pane; remembered. |
| `ctrl-t` | Toggle this window / all windows. |
| `ctrl-r` | Refresh. |
| Mouse wheel, `shift-up/down`, `alt-up/down` | Scroll the preview, pausing follow and refresh; Alt moves half pages. |
| `ctrl-f` | Resume following new output; selecting another agent also resumes. |
| `page-up/down` | Page the agent list. |

Names shorten under project headings. Search parts, such as `claude tmux secondary`, rather than a full hyphenated name. A hidden agent's bell displays an alert; it alone proves neither completion nor a blocker.

### States and worked time

| State | Meaning and next action |
| --- | --- |
| `⠹ working` | Working or waiting on delegated work, requests or reported background work. |
| `○ idle` | No task yet, or a top-level turn ended with nothing pending; ready for the next prompt. Pending work keeps top-level agents working. |
| `✓ done` | A helper/member replied to its parent. A new request starts work again. |
| `⚠ permission` | Waiting for approval; open its pane. Auto mode is configurable, not a guarantee against prompts. |
| `◆ needs you` | A helper/member ended its turn without replying or waiting on work; inspect its question. |
| `✉ message waiting` | Delivery has waited past the attention threshold; finish typing/scrolling, do not resend. |
| `✗ exited` | Process exited; its pane/history remains until closed. |
| `- untracked` | No turn tracking or worked time; messaging still works. |

Helpers report progress with `tmux-agent-report --from ME "running tests"`. Before ending a turn to wait, use `tmux-agent-report --from ME --waiting "test run"`; a progress notice to your own parent also keeps you working. Normal reports or new requests clear the wait; replying to the parent marks done. Claude background commands are detected automatically; Codex needs `--waiting`. Never use it to hide a user question. An idle turn does not ask for attention.

`4m · worked 1h5m` means current-state age and total active working time. Permission, needs-you and message waits pause the same turn; idle/done complete it. Pauses do not count. Reopening retains saved work; abrupt removal can lose the uncheckpointed interval. See [accounting](design/state-and-protocol.md#working-time-accounting) and [preview details](design/sub-agents.md#browsing-tmux-agents).

### Close and reopen

Parents dismiss finished helpers with `tmux-dismiss --from ME PEER`; users can close any agent. Dismissal closes descendants first, retaining records. `--keep-children` leaves direct children unowned. `--done` skips members and any subtree containing members or unfinished work. Parents see closures in `tmux-peers`, without interruption.

Closed conversations remain listed for [7 days by default](configuration.md). `enter` reopens, `ctrl-o` reopens and jumps, `ctrl-x` forgets. Reopening always uses a hidden window, preserving membership and reconnecting to the original parent if still live; otherwise the [resume rules](design/sub-agents.md#closing-and-telling-the-parent) apply.

`tmux-spawn --from ME --resume PEER` requires a unique closed match. For duplicate names, use `--list-closed`, then `--resume-id ID`. Labels may acquire a suffix if taken. Codex must finish a turn before its conversation can be reopened. Saved messages follow the original identity, never another agent reusing its label. Legacy records migrate automatically; see [recovery instructions](design/state-and-protocol.md#recovery).

### Members and ownership

| Role | Lifecycle |
| --- | --- |
| Ordinary helper | Task-specific; parent dismisses when finished. |
| `--member` | Long-lived; excluded from default list, ordinary chip counts and done cleanup. `ctrl-a` reveals it; attention still appears. Close explicitly. |

Only top-level callers can create members, including for another owner. Existing agents cannot convert to members; restart the chain.

`tmux-spawn --from ME --for PEER "brief"` creates a helper owned by that connected peer, linked only to it and initially idle. The owner receives the brief, introduces itself and sends the first task. Add `--member` for a standing member.

Depth always counts from the caller plus one, including `--for`; default maximum is two. Helpers do not inherit membership. A chain's main creates both members at depth 1, leaving depth 2 for worker helpers. See [Starting agents](#starting-agents) and the [chain skill](../skills/agent-chain/SKILL.md) for layout and handoff.

## Renaming agents

Suggested names use `<kind>-<dir>-<N>`, with `~` for home. A recognised recorded kind supplies `claude` or `codex` despite launch wrappers; configured Codex profiles use `codex`. Unrecognised kinds or removed profiles fall back to the current command, omitting shell prefixes.

`--name auth-review` adds that kind/directory prefix, keeping an already matching prefix. Spawn suffixes collisions; rename refuses them. Prefixed mode sanitises characters; exact mode validates them. See [character rules](design/state-and-protocol.md#naming) and [configuration](configuration.md).

`tmux-rename --from ME PEER main` renames yourself or a descendant; the user can omit `--from` to rename any agent. `--exact` keeps the supplied name verbatim. The agent and peers receive notices. Use the printed full name thereafter; old names have no aliases. IDs, ownership, queued messages and history survive. Only live labels must be unique. `tmux-connect --as NEW` also renames, keeping its verbatim-name behaviour.

## More than one Codex account

Configure existing homes with the [Codex profiles recipe](configuration.md#codex-profiles), then rerun the installer for their skills and rules. `tmux-agents start work` launches a tracked top-level agent; `tmux-spawn work --from ME "task"` launches a helper whose children inherit that profile. Optional [shell wrappers](../integrations/sh/codex.sh) pin identity only.

## Commands

Agent commands below use actual names for `ME`/`PEER`. See each command's `--help` for full syntax.

| Command | Purpose |
| --- | --- |
| `tmux-agents start claude\|codex\|PROFILE [-- AGENT ARGS]` | Launch a tracked independent agent. |
| `tmux-agents start chain [DIR] [--worker AGENT]` | Start a chain in a new window. |
| `tmux-connect [target] [--as NAME] [--all]` | User's connection picker or direct target. |
| `tmux-connect --from ME TARGET` | Agent connection by type, name or pane. |
| `tmux-rename --from ME PEER NAME [--exact]` | Rename yourself or a descendant. |
| `tmux-disconnect [name]` | User unlinks one peer or all. |
| `tmux-peers --from ME [--ids]` | Show identity and connections. |
| `tmux-ask --from ME [--any] [--reply\|--notice] PEER [msg]` | Send request, answer or notice; accepts stdin. `--any` permits unlinked targets. |
| `tmux-ask --pending` | Inspect queued/undelivered messages. |
| `tmux-ask --retry [--to PEER]` | Retry saved messages. |
| `tmux-peek --from ME PEER [lines]` | Read peer output; default 40 lines. |
| `tmux-spawn [claude\|codex\|PROFILE] --from ME [--member] [task]` | Spawn; accepts stdin, `--name`, `--split` and `--for`. |
| `tmux-spawn --list-closed` | List saved conversations. |
| `tmux-spawn --from ME --resume PEER` / `--resume-id ID` | Reopen a conversation. |
| `tmux-agent-report --from ME [--waiting] "text"` | Report progress or a work wait. |
| `tmux-agents` | Open the agent list. |
| `tmux-dismiss --from ME PEER` | Close a descendant and its subtree. |

## Slow popup startup

Slow shell initialization can delay popups before tmux-agents runs. See [performance diagnostics](performance.md) to measure startup and keep interactive setup out of non-interactive shells.
