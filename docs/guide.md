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
tmux-agents start AGENT [--name NAME [--exact]] [-- AGENT ARGS]
```

Choose `claude`, `codex`, a configured Codex profile or an executable basename on PATH; profiles take precedence over same-named executables. The launcher names the pane. For Claude/Codex it pins identity and supplies turn tracking without editing global agent configuration. Other executables have [limited support](agents.md), without automatic tracking, permission setup or resume. It keeps the agent's permission defaults. Arguments after `--` pass through unchanged, including resume arguments; top-level sessions cannot be reopened with `tmux-spawn --resume`.

Plain Claude/Codex launches start idle. Incoming requests, progress reports or turn-start hooks start work; opaque agent arguments do not change the initial state. Agents without tracking show `-` and no worked time, but can still exchange messages. Codex shell wrappers pin identity only; prefer `start` for tracking.

Exiting saves work, clears agent state and returns to the shell. Reusing a named pane from its own terminal retains its name and connections; `--name` can rename it first. Invalid or taken names refuse without changing it. Another terminal cannot take over a named pane.

For another independent agent, split manually and run `start` there. For a connected helper, ask your agent to use `tmux-spawn --split`.

```sh
tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--secondary AGENT] [--worker AGENT]
```

This opens a window in DIR (default `$PWD`) and starts the selected main. Without `--target`, it opens and focuses the new window in the current tmux session. With `--target session[:index]`, it creates a detached window in an existing session without changing focus; a bare session uses its next free window index. Target mode needs no caller pane or `TMUX` variable when tmux can reach the existing server. The window name is `--name NAME`, or DIR's basename by default (`root` for the filesystem root). Both `automatic-rename` and `allow-rename` are disabled before the agent starts. Chain `--name` names the window; `start AGENT --name` names the agent pane.

A Claude/Codex main receives the chain request; other executables receive no initial prompt, so send the actual brief manually with `tmux-ask` after they reach their prompt. For Claude/Codex, the [agent-chain skill](../skills/agent-chain/SKILL.md) creates its secondary and worker members. Each role accepts Claude, Codex, a configured Codex profile or an executable basename on PATH; defaults are `claude`/`claude`/`codex`. Inspect them with `tmux-agents chain-config --sources`; see [Chain roles](configuration.md#chain-roles) for precedence and instruction-file preferences.

Options can appear before or after DIR. All three role choices are validated before creating the window. Success writes exactly the new pane ID followed by a newline to stdout; errors go to stderr with a nonzero exit status.

```sh
tmux-agents start chain . --target work --name review --worker codex
tmux-agents start chain --target work:4 --name review . --main codex
```

These examples require an existing `work` session; `work:4` requires a free window index. There is no new socket flag. For a named server, use a `tmux -L NAME` wrapper on PATH, or set `TMUX` to that server's socket path. For isolated testing, obtain and validate the path before invoking the launcher (the named test server must already be running with stub agents):

```sh
if tmux -L chain-test has-session; then
  chain_socket=$(tmux -L chain-test display-message -p '#{socket_path}')
  case "$chain_socket" in
    ''|*/default) echo 'Unsafe test socket' >&2 ;;
    *) TMUX="$chain_socket" tmux-agents start chain . --target work --name review ;;
  esac
fi
```

Saying “start the chain” to an existing top-level agent keeps it as main. Role settings affect new chains only. Main keeps its permission defaults; Claude/Codex members use `sub_auto` (default `on`). Codex main has identity pins and turn-end notify, but no turn-start hook, so a direct user task that spans several turns starts with `tmux-agent-report --from ME --local "<task>"` and ends with `--local-done`; a task finished within one turn needs neither.

## Shell panes

Press `prefix + C-s` to choose a command from saved shell history or type a new command. The picker supports fish, bash and zsh, deduplicated newest first. Enter accepts the selected history entry, or your query when nothing matches. Alt-Enter always runs the query; Esc cancels without creating a pane. The history picker uses fish for fish history and Perl for bash/zsh history, with fzf for selection; it needs no Python runtime.

Press `prefix + S` for a plain interactive shell. Both modes run in a hidden `agents-<project>` session, in the opener's current directory, and show a popup. The lowercase `prefix + s` keeps tmux's session picker. [Configure both shortcuts](configuration.md#shell-popup-key) before sourcing the tmux configuration; `none` disables either one.

```sh
tmux-shell [--from AGENT] [--client CLIENT] [--pane OPENER]
tmux-shell --from ME --command 'printf "%s\n" "hello world"'
tmux-shell --pick
```

Commands run through the configured default shell, so fish syntax and shell functions work as they do in that shell's command environment. Pass the entire command as one argument; quoting, dollar signs, semicolons and newlines are command data until that shell executes them. Agents pass `--command` directly instead of opening the picker.

A command exiting zero shows `ok` and counts down for three seconds before closing. Press any key during the countdown to keep the pane and enter an interactive shell. A nonzero exit shows `failed N` and immediately leaves an interactive prompt in the same working directory. Configure the nonnegative integer `@tmux_agents_shell_close_secs` or `TMUX_AGENTS_SHELL_CLOSE_SECS`; `0` closes successful commands immediately.

`--client` selects the popup client. `--pane` selects the opener and directory, never ownership. User-created panes are independent, even when opened from an agent pane. Agents always supply their actual name with `--from ME`; dismissing an owner recursively closes its command and shell panes and clears owned command records.

`prefix + d` detaches while work continues. `prefix + a` shows command text and `running`, `ok` or `failed N`. Enter reopens a live pane. After a command pane exits, its result stays listed until `ctrl-x` clears it; a completed record only shows details and cannot reopen or rerun a command. `ctrl-x` on a live command closes it and clears its record. Plain shells leave no record when they exit. Command records are not agent conversations and have no resume, task protocol or worked-time accounting.

The picker asks the configured fish shell for `history --null`; this starts fish with its non-interactive configuration, so custom history functions and startup settings can affect the result. Bash/zsh history files are parsed as data using Perl. Commands still buffered by another shell may not be visible. `HISTFILE` overrides bash/zsh defaults when exported; fish uses its exported history name and XDG data directory. Timestamped bash history can preserve multiline entries; without timestamps each line is treated as a separate entry because command boundaries are ambiguous. History entries are not executed while loading, and unsupported shells still allow a new query. This records command text and result, not terminal output or a transcript of later interactive commands.

All shell message and target guards also apply to command panes. Borders show only their name; they are not agent peers. `tmux-ask` refuses them, including `--any`, `--reply` and queued retries. `tmux-connect`, `tmux-rename` and `tmux-spawn --for` or `--split` refuse shell targets. `tmux-peek --from ME SHELL` may read a live shell owned by you or one of your descendants.

## Connecting agents

Press `prefix + A` to connect existing panes. The popup previews this window's panes; `ctrl-a` switches to every window and remembers that choice. For unnamed panes, ↑/↓ selects name fields, typing edits and Enter accepts.

Or tell your agent “connect codex and ask it to review this diff”. It runs `tmux-connect --from ME codex`, then sends the request. Agent mode generates names without a form. `claude`/`codex` selects that type in this window; multiple matches require choosing an exact name or pane ID.

For another window, use `codex@stone-age` (project name or part), `claude@2` (window) or `claude@work:2` (session and window). `tmux-connect --from ME --list` lists candidates when the description is less specific. Cross-window connections send the other agent a notice. Type and `kind@window` shortcuts are Claude/Codex only; connect other agents by exact name or pane ID.

Borders show `name ⇄ peers`. Links are one-to-one: A↔B and B↔C do not link A↔C. See [naming](#renaming-agents) for generated labels.

## How messages flow

Use `tmux-ask --from ME PEER "task"` for requests, `--reply` for answers and `--notice` for information needing no work or reply. Requests include reply instructions; the sender ends its turn and receives the answer later. A request saying “no reply needed” still starts work and makes the sender await a reply. Replies do not invite another reply.

For a message already saved in a file, use `--message-file`:

```sh
message_dir="${TMPDIR:-/tmp}/tmux-agents/$ME"
mkdir -p "$message_dir"
message_file="$(mktemp "$message_dir/message.XXXXXX")"
# write the request to "$message_file"; remove after a successful send
tmux-ask --from ME PEER --message-file "$message_file"
```

The file must be one readable regular file, not a symlink, and at most 1 MiB. Its literal text is sent unchanged; empty files use the usual empty-message validation. The option conflicts with positional message text and ignores stdin without reading it.

Reply instructions follow the receiving agent: Claude uses the supplied quoted heredoc form; Codex, including configured profiles, uses quoted short arguments or a unique `mktemp` file with `--message-file` as above. Unknown executables receive quoted plain argv for portability. These forms leave request IDs and matching unchanged; preserve the supplied sender, target, `--request-id` and `--any` when present.

In Codex code mode, `exec_command` is still a shell tool: wrapping it in JavaScript does not bypass shell parsing or sandbox permissions. Prefer quoted arguments or `--message-file` to heredocs. Run one tmux command per tool call, separately from file creation and cleanup, without shell command chains or pipes. Substitute the unique file's actual path if variables do not persist across calls. If a tmux socket permission denial persists with that form, retry only that command with narrowly escalated permissions and a short justification.

Each request has its own ID. Use the supplied reply command, including `--request-id RID`: `tmux-ask --from ME --reply --request-id RID PEER "answer"`. This completes that request even when PEER is not your parent. With the older `--reply PEER` form, a single pending request between the pair is matched automatically; several pending requests are refused with their IDs so you can select the one answered. Legacy messages without tracking remain compatible but cannot complete unrelated tracked requests. Queuing, retry, reopening and renaming preserve request association.

Typing or scrolling delays delivery. `queued` means sent: do not resend. Leaving copy mode or becoming idle allows delivery in order; [configuration](configuration.md) controls idle, copy-mode and attention thresholds. Long waits show `✉`. If the receiver disappears, the message stays saved and the sender is notified; reopening a resumable receiver retries its messages.

Use `tmux-ask --pending` to inspect saved messages and `tmux-ask --retry --to PEER` to retry a live receiver, or omit `--to` for all available receivers. Unavailable destinations stay saved.

Message markers separate agent text from any user draft submitted with it. Agents treat text outside the markers as yours. Long reports use a summary plus file path; messages over the configured limit (default 60 lines) are saved automatically, with the first 15 lines and path delivered.

## Sub agents

Agents use `tmux-spawn` instead of built-in sub agents so each helper has a real pane and readable history:

```sh
tmux-spawn --from ME --name auth-review "Review src/auth.ts"
```

For a task already saved in a file, use `--message-file`:

```sh
task_file="$(mktemp "$message_dir/task.XXXXXX")"
# write the task to "$task_file"; remove after successful delivery
tmux-spawn --from ME --name auth-review --message-file "$task_file"
```

`--message-file` accepts one readable regular file (not a symlink), up to 1 MiB, and sends its literal text. Empty content follows normal no-task behavior. It conflicts with positional task text and ignores stdin without reading it; it cannot be combined with `--resume` or `--list-closed`. Use a unique `mktemp` file under `${TMPDIR:-/tmp}/tmux-agents/$ME/` for each message so agents sharing a working directory cannot overwrite one another or dirty the project. Remove the file after a successful send, or keep its unique path for a retry.

### Start a helper

Helpers inherit the caller's agent kind and Codex profile. To choose another, put `claude`, `codex`, a configured profile or an executable basename before the options. For other executables, a supplied spawn task is not sent: use the printed full name and resend the actual brief with `tmux-ask` once the agent is at its prompt. See [manual task delivery](agents.md#sending-the-first-task). They open hidden, one window each in a project session such as `agents-api`. Use the full name printed by spawn; [naming rules](#renaming-agents) apply.

| Spawn option | Effect |
| --- | --- |
| `--split PEER` | Place the helper visibly beside a named pane, using the caller's directory. |
| `--right` / `--below` | Choose direction with `--split`; right is the default. |
| `--size N%` | Choose its share with `--split`; default 50%. |

Splits keep the same ownership and depth rules and do not switch your focus. New and resumed Claude/Codex helpers, including members, default to auto permissions. [Set `sub_auto` off](configuration.md) to use agent defaults; this setting does not affect top-level `start`.

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
| `✓ done` | All incoming requests are answered and no other work remains. A new request starts work again. |
| `⚠ permission` | Waiting for approval; open its pane. Auto mode is configurable, not a guarantee against prompts. |
| `◆ needs you` | An agent explicitly requested user attention, or ended its turn with unfinished work and no agent or background wait; inspect its question. |
| `✉ message waiting` | Delivery has waited past the attention threshold; finish typing/scrolling, do not resend. |
| `◷ reply overdue` | A delivered, unanswered request has no observable progress for the configured interval; inspect the receiver. This does not change its work state. |
| `✗ exited` | Process exited; its pane/history remains until closed. |
| `- untracked` | No turn tracking or worked time; messaging still works. |

For a user question or decision, run `tmux-agent-report --from ME --needs-you "reason"` before asking. Tracked top-level agents also appear in the default list and status chip while they need you. The reason is shown as activity and survives turn end; ordinary progress or turn start clears the explicit attention. Pending requests stay pending.

Done agents show their last report as `done · <text>` in list activity and the status chip. With no report, the list keeps `no report yet` and the chip shows `done`. The list truncates the combined text to its activity column; tmux clips the chip to available status-line space. Stored activity and preview text stay unchanged.

Helpers report progress with `tmux-agent-report --from ME "running tests"`. Before ending a turn to wait, use `tmux-agent-report --from ME --waiting "test run"`; a progress notice to your own parent also keeps you working. A normal progress report clears the wait. A new request clears a parent-notice coordination marker but preserves an explicit `--waiting` background wait. A reply completes only its matching request; other requests, parent tasks, local work and background waits remain active. Once all incoming requests are answered and no other work remains, the agent returns to the appropriate done or idle state. Claude detects its own background shell commands at turn end; Codex needs `--waiting`. Neither mechanism knows when arbitrary external work has finished. Never use it to hide a user question. An idle turn does not ask for attention.

A direct user prompt is local work for the turn it starts, and ends with that turn once nothing else is outstanding; no report is needed. For local work that spans turns (you will keep going after this turn without a request, child or background wait to show for it), run `tmux-agent-report --from ME --local "<task>"` at the start and `tmux-agent-report --from ME --local-done` when that work is complete. `--local-done` takes no trailing text and only clears local work; incoming requests, outgoing waits, unfinished children and background waits still prevent completion. Ordinary progress reports within a request do not create an independent local task.

Claude's nonprotocol user turn-start marks local work automatically, and the turn end clears it. Codex has no turn-start hook: for multi-turn direct work, report `--local` when the task begins so peer replies cannot finish it in the meantime. Codex's completion notification also uses its input messages to recognise direct local work, but only at turn end. Use `--local` for each new multi-turn direct task, including repeated identical text: without a turn ID, identical notification payloads cannot be distinguished from retries. `--local` resets notification deduplication. The local completion marker survives resume. Complete explicit local work with `--local-done`; use a normal progress report after a background wait ends.

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
| `tmux-agents start AGENT [-- AGENT ARGS]` | Launch an independent agent; Claude/Codex have tracking. |
| `tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--secondary AGENT] [--worker AGENT]` | Start a chain in a new window. |
| `tmux-connect [target] [--as NAME] [--all]` | User's connection picker or direct target. |
| `tmux-connect --from ME TARGET` | Agent connection by type, name or pane. |
| `tmux-rename --from ME PEER NAME [--exact]` | Rename yourself or a descendant. |
| `tmux-disconnect [name]` | User unlinks one peer or all. |
| `tmux-peers --from ME [--ids]` | Show identity and connections. |
| `tmux-ask --from ME [--any] [--reply\|--notice] [--request-id RID] PEER [msg...]` or `--message-file FILE` | Send request, answer or notice; accepts stdin when no message file is supplied. `--any` permits unlinked targets. |
| `tmux-ask --pending` | Inspect queued/undelivered messages. |
| `tmux-ask --retry [--to PEER]` | Retry saved messages. |
| `tmux-peek --from ME PEER [lines]` | Read peer output; default 40 lines. |
| `tmux-shell [--from AGENT] [--client CLIENT] [--pane OPENER]` | Open an independent or explicitly owned shell popup. |
| `tmux-spawn [AGENT] --from ME [--member] [task]` or `--message-file FILE` | Spawn; accepts stdin when no task file is supplied, `--name`, `--split` and `--for`. |
| `tmux-spawn --list-closed` | List saved conversations. |
| `tmux-spawn --from ME --resume PEER` / `--resume-id ID` | Reopen a conversation. |
| `tmux-agent-report --from ME [--waiting\|--local\|--needs-you] "text"` | Report progress, a work wait, multi-turn local work or user attention. |
| `tmux-agent-report --from ME --local-done` | Complete `--local` work only; takes no trailing text. |
| `tmux-agents` | Open the agent list. |
| `tmux-dismiss --from ME PEER` | Close a descendant and its subtree. |

### Standard input by command

| Command | What it reads | Agent message file? |
| --- | --- | --- |
| `tmux-ask` | User-authored message body when no positional text is supplied. | Yes. Use `--message-file` for saved text. |
| `tmux-spawn` | User-authored task/brief when no positional task is supplied. | Yes. Use `--message-file` for saved text; other executables still need manual `tmux-ask` delivery. |
| `tmux-agent-report` | Hook payloads, including Claude hook JSON and progress/notification protocol data. | No. This is protocol input, not a user message. |
| `tmux-connect` | Interactive numeric selection and key input. Other reads are generated row pipelines. | No. This is interaction, not a message body. |
| `tmux-dismiss` | Confirmation is read from `/dev/tty`, not caller stdin. | No. |
| `tmux-agents` | `fzf` selection input comes from generated rows; keypresses use the terminal. | No. |
| `tmux-shell` | Popup metadata comes from an internal here-string. | No. |
| `tmux-shell-history` | Internal history files and shell-history subprocess output; interactive confirmation is terminal input. | No. |
| `tmux-shell-run` | Interactive keypresses from the terminal. | No. |

## Slow popup startup

Slow shell initialization can delay popups before tmux-agents runs. See [performance diagnostics](performance.md) to measure startup and keep interactive setup out of non-interactive shells.
