# tmux-agents guide

The operating details behind the [README's use cases](../README.md#common-use-cases). See [DESIGN.md](../DESIGN.md) for implementation and recovery notes.

Agent examples use `ME` and `PEER` as placeholders for actual full names. Claude and pinned Codex (`TMUX_AGENTS_PINNED=1`) can omit `--from` for messaging, spawn, reports, missions and opening agents. Unpinned Codex supplies its verified name because its shared command process may identify another pane. Explicit ownership remains required for shell panes and agent-mode connect/rename/dismiss.

## Status and resuming

`tmux-agents status [--notes] [--handoff] [--missions full] [PEER]` gathers the routine orientation checks; `resume` is an alias. It shows your identity, role, parent, depth and kind; peers with state, age and waiting descendants; the configured roles; open project missions with the last three log lines for missions you own; unread-note counts and senders; queued-message counts; and the project-root `HANDOFF.md` state. Empty sections are omitted. Role lookup uses `@role`, falling back to the name suffix. `tmux-peers --me` prints just your name.

When the caller has no `@parent` or `@role`, status prints a claim hint; `status PEER` never prints it. Run `tmux-agents role ROLE [--from ME]` to claim your own live named top-level pane as `main`, `designer`, `interface`, `worker`, `reviewer`, `runner` or `researcher`; `secondary` aliases `interface`. Missing tracking starts idle and a missing agent ID is created. Repeating the same role preserves state; a different existing role is refused. Parented helpers keep their spawn role and cannot claim any role. Trusted panes may omit `--from`; unpinned Codex supplies its verified name.

`--notes` prints unread notes and marks them read. `--missions full` expands mission details. Plain `status` never prints the handoff body: it reports absent/present, tracking and ignore state, and warns if tracked. `--handoff` explicitly includes the body. Resume after a context clear belongs to the separately maintained wrap-up skill; `status` remains a read-only orientation command. `status PEER` shows that agent's state and last five screen lines.

## Opening an agent

Run `tmux-agents open NAME` to show an exact live agent name to the user. It uses the most recently active client showing the caller's session. Hidden agent sessions schedule the same popup viewer as the list without waiting for it to close; other panes become the client's active pane. Detaching the viewer returns to the list. Unknown or exited agents and sessions without a client produce an error. No peer connection is required.

## Dependencies

Requires tmux 3.2+ and bash; the agent list also needs fzf. Other commands work without fzf. See [installation](../README.md#install).

To try installation safely, run `./install.sh --home /tmp/tmux-agents-home`.
The installer creates that home, keeps inherited `CODEX_HOME`, `TMUX_AGENTS_CODEX_HOMES`
entries and `BIN_DIR` only when they resolve inside it, and defaults commands to
`DIR/.local/bin`. It skips turn-state migration, and
prints configuration paths for the sandbox. `--dry-run` previews without writing.
Without `--home`, linked worktrees and destinations outside `$HOME` are refused
before any write, including in dry-run mode. `--force` explicitly overrides those
guards for a normal install and also backs up and replaces conflicting real files.
Codex homes outside `$HOME` therefore need `--force`. Sandbox installs still cannot
write outside their home, and `/` is refused as HOME even with `--force`.
All installs discover Codex accounts only from environment variables, never tmux
settings; export the account map before installing profiles configured only in tmux.
Runtime discovery is unchanged: empty account maps still fall back to tmux settings.

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
tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--main-resume ID] [--interface AGENT] [--worker AGENT] [--designer AGENT] [--reviewer AGENT] [--runner AGENT] [--researcher AGENT]
```

This opens a window in DIR (default `$PWD`) and starts the selected main. Without `--target`, it opens and focuses the new window in the current tmux session. With `--target session[:index]`, it creates a detached window in an existing session without changing focus; a bare session uses its next free window index. Target mode needs no caller pane or `TMUX` variable when tmux can reach the existing server. The window name is `--name NAME`, or DIR's basename by default (`root` for the filesystem root). Both `automatic-rename` and `allow-rename` are disabled before the agent starts. Chain `--name` names the window; `start AGENT --name` names the agent pane.

Add `--main-resume ID` to resume only the main conversation; mission agents start fresh. Claude receives `--resume ID`, then the launcher waits for its empty input prompt, submits `/rc`, and sends the chain brief. If `/rc` opens the already-connected Remote Control management dialog, the launcher uses its Esc-to-continue action first. Codex and configured Codex profiles receive `resume ID` with the brief, without `/rc`. Chain naming is unchanged. The option expects a conversation UUID from Claude's project session file or a rollout file in the selected Codex home. Missing, malformed, unavailable or wrong-kind IDs warn on stderr and start a fresh main; unsupported executables also warn and start fresh. Stdout remains only the pane ID. If Claude does not reach an empty prompt within about a minute, a warning appears in its pane and the brief is not sent; resolve startup dialogs and send the brief manually.

A Claude/Codex main receives the chain request; other executables receive no initial prompt, so send the actual brief manually with `tmux-ask` after they reach their prompt. For Claude/Codex, the [agent-chain skill](../skills/agent-chain/SKILL.md) starts mission teams: main opens a designer's pane for discussion, then after plan approval spawns an interface member to dispatch independent workers. Reviewer, runner and researcher serve individual tasks. Hidden panes are the default; split only when requested. `secondary` remains an alias for `interface`, including `--secondary`.

Inspect all seven roles and model arguments with `tmux-agents chain-config --args --sources`; roles accept Claude, Codex, configured profiles or executable basenames on PATH. `tmux-agents status` includes the resolved roles. All seven agents and their args are snapshotted at chain launch and forwarded to descendants; `@role main` identifies the main pane. A main started outside the chain launcher claims it with `tmux-agents role main --from ME`, so the board pins its tree. See [Chain roles](configuration.md#chain-roles) for settings and precedence.

Main tracks independent missions without a cap using `tmux-agents mission add TITLE`, `show ID`, `list` and `tmux-agents board --watch`. Only the owner writes a mission; main may set any mission. `tmux-spawn --role designer --mission ID --open "brief"` validates the mission, assigns its new owner, logs the spawn and opens the pane for the user. After plan approval, `--role interface --member --mission ID` transfers ownership to the interface; its workers use `--role worker` without taking ownership.

`tmux-agents mission set ID --status S [--notify PEER] [--notice]` changes state and optionally sends a note, or a notice with `--notice`. The default notification is `ID status: old -> new`. `mission done ID "report path or summary" [--notify NAME]` marks done, logs completion and optionally sends a note. `tmux-ask --note PEER --mission ID "progress"` and `tmux-agent-report --mission ID "progress"` also append local mission progress; `mission log ID TEXT --kind K` remains available. Routine updates are notes; send the awaited completion reply separately. Main dismisses the team only after that reply, once changes are landed and checks complete. See the [chain skill](../skills/agent-chain/SKILL.md#missions) for the approval and landing flow.

`tmux-agents ci [--watch] [REF]` summarizes GitHub Actions runs for a commit (default HEAD). `--watch` waits for completion. Output is limited to 20 lines, including a failing job's log tail. Hand a runner the brief “run `tmux-agents ci --watch` and reply” when waiting belongs to a helper.

Options can appear before or after DIR. All seven role choices are validated before creating the window. Success writes exactly the new pane ID followed by a newline to stdout; errors go to stderr with a nonzero exit status.

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

Saying “start the chain” to an existing top-level agent keeps it as main. Role settings affect new chains only. Main keeps its permission defaults; Claude/Codex members use `sub_auto` (default `on`). Codex main has identity pins and turn-end notify but no turn-start hook. Use a plain `tmux-agent-report "<task>"` to show directly typed work before turn end.

## Project launchers

`tmux-agents chain [DIR]` wraps `start chain`. With no DIR, fzf offers the current directory, configured project directories, then Git repositories under the configured scan root at depths 1 and 2. There are no built-in projects and no default scan root. Scanning stops at a repository; `--include-worktrees` also includes `.git` files. Without a terminal or fzf it warns and uses the current directory. Esc cancels. `--filter QUERY` selects noninteractively through fzf.

Use `--target session[:index]`, `--name NAME` and `--main-resume ID` as with `start chain`. A successful launch saves a bare directory line unless `--no-save` is used; `--save` restores saving, and the last save flag wins. Existing lines with that directory, including field-carrying lines, prevent duplicates. The picker chooses directories; configured window fields apply when opening the sequence. Set an explicit `--main-resume` to resume a picker launch. Both launchers honor the [project settings](configuration.md#project-launchers).

`tmux-agents main-sequence` opens the configured windows in line order in session `main`, then joins through a separate `main-N` client session. Clients share windows but select them independently; their sessions disappear on detach. The base session survives. Existing windows stay unchanged unless `--add-missing` adds missing names, using the configured index when free or appending otherwise. `--no-attach` opens windows without creating a client session. Empty configuration creates no session. Configure unique names when opening the same directory more than once.

The shared project file is `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agents/projects`. Until it exists, the commands read `~/.config/tmux-main-sequence/projects`. The first edit or new save copies the fallback content into the new path without changing the old file. `TMUX_MAIN_SEQUENCE_CONFIG` overrides both paths. The row grammar is `DIR [name=NAME] [shell] [command=CMD] [resume=ID]`. `~` expands to HOME; quote paths or values containing spaces. Blank lines and `#` comments are preserved. Unknown fields warn and are ignored. `shell` and `command=CMD` open plain windows and ignore `resume` with a warning; `shell` is redundant alongside `command`. A resume field remains until explicitly removed.

A command runs in DIR through the server's `default-shell` as `SHELL -c CMD`, falling back to `$SHELL` and then `/bin/sh`. When it exits, including on failure, the window keeps an interactive instance of the same shell so its output remains visible. Config parsing never executes command text. Quote the whole command value as one token.

```text
~ name=dashboard command="tmux-agents board --watch"
~ name=home
~/projects/example name=example
"~/projects/two words" name="two words" shell
```

Use the same commands from a shell or an agent; no manual file editing is needed:

```sh
tmux-agents main-sequence list
tmux-agents main-sequence add ~/projects/example name=example
tmux-agents main-sequence add ~ name=dashboard command="tmux-agents board --watch" --at 1
tmux-agents main-sequence set dashboard command="tmux-agents board --watch"
tmux-agents main-sequence unset dashboard command
tmux-agents main-sequence set example resume=11111111-1111-4111-8111-111111111111
tmux-agents main-sequence unset example resume
tmux-agents main-sequence --no-attach
tmux-agents main-sequence --add-missing
```

`add` appends unless `--at N` inserts before project N (1-based, counting project records rather than comments); N one beyond the last project appends. `set` and `unset` match a directory or a configured/default window name and print the resulting line. Ambiguous matches error and list candidate lines, so use a unique name. `set` and `unset` edit only the named `command` or `resume` field. Removing `command` leaves a plain window only if `shell` is also present; otherwise the row starts a chain. Edits preserve other lines, comments and order. `list` prints the source file, including comments. These config commands do not launch agents.

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

All shell message and target guards also apply to command panes. Borders show only their name; they are not agent peers. `tmux-ask` refuses them, including `--any`, `--reply` and queued retries. `tmux-connect`, `tmux-rename` and `tmux-spawn --for` or `--split` refuse shell targets. `tmux-peek SHELL` may read a live shell owned by you or one of your descendants.

## Connecting agents

Press `prefix + A` to connect existing panes. The popup previews this window's panes; `ctrl-a` switches to every window and remembers that choice. For unnamed panes, ↑/↓ selects name fields, typing edits and Enter accepts.

Or tell your agent “connect codex and ask it to review this diff”. It runs `tmux-connect --from ME codex`, then sends the request. Agent mode generates names without a form. `claude`/`codex` selects that type in this window; multiple matches require choosing an exact name or pane ID.

For another window, use `codex@stone-age` (project name or part), `claude@2` (window) or `claude@work:2` (session and window). `tmux-connect --from ME --list` lists candidates when the description is less specific. Cross-window connections send the other agent a notice. Type and `kind@window` shortcuts are Claude/Codex only; connect other agents by exact name or pane ID.

The COMMAND column in `tmux-peers` and `tmux-connect --list` shows the recorded agent kind or Codex profile for tracked agents, rather than a launcher shell. It adds `(exited)` when that executable is absent from the pane process tree. Untracked and shell panes retain the raw foreground command. Type shortcuts use the same agent identity.

Borders show `name ⇄ peers`. Links are one-to-one: A↔B and B↔C do not link A↔C. See [naming](#renaming-agents) for generated labels.

## How messages flow

Use `tmux-ask PEER "task"` for requests, `--reply` for answers and `--notice` for information needing no work or reply. Requests include reply instructions; the sender ends its turn and receives the answer later. A request saying “no reply needed” still starts work and makes the sender await a reply. Replies do not invite another reply.

Use `tmux-ask --note PEER "progress"` for quiet progress, handoff updates, partial completion and plan updates. A note is stored immediately without pasting a prompt, starting a turn or waiting for typing. `--note` is mutually exclusive with `--reply` and `--notice`; it supports `--any` and the file and summary forms below. Empty notes are rejected. Notes follow the receiver's stable agent ID, including while its record is closed, and remain readable after reopening for up to seven days. Adding `--mission ID` appends progress to the local mission log. Mission logging is local only.

Keep awaited results and matters requiring the user on ordinary `--reply`, request or `--notice` messages: release completion, CI failure, push approval and decisions must never be notes. A decision request includes the default and what is blocked. Main agents read notes for a concise update when the user asks or at a natural pause, rather than repeating every entry.

Read `tmux-notes` to see unread notes grouped by sender, ordered by time within each group, with `HH:MM` and message IDs. Each receiver has one read cursor over increasing note IDs. Reading advances it to the last printed note; `--keep-unread` preserves them. `--all` includes read notes, `--since 10m` or `--since 2h` limits the time range, and `--count` prints only the unread count without consuming notes. Summary attachments still use `tmux-read <id>` for their full text.

For a Claude statusline, bare `tmux-notes --count` reads the current `$TMUX_PANE` with one tmux lookup and no Perl or JSON scan. Missing pane identity or note storage prints `0`. For example, this fragment appends the unread count to an existing statusline script; it does not change Claude configuration:

```sh
unread="$(tmux-notes --count)"
printf '%s unread' "$unread"
```

Claude's `UserPromptSubmit` hook supplies an unread-note summary at turn start, with sender counts, the latest first line and the command to read them; it is silent with no unread notes. Codex has no prompt hook, so its skill requires `tmux-agents status --notes` once at the start of each turn. A hook summary leaves notes unread; a successfully delivered digest advances the cursor to its last included note.

Digests apply to all tracked idle or done agents, including interface agents and sub agents. An idle receiver gets a digest notice after about 5 minutes, including sender counts and latest first lines. It requires new unread notes since the previous digest and skips working, needs-you and permission states. After another idle interval, a new batch gets a digest beginning with `Continuing from last update ...`; it contains only new notes. Both agents reset continuation after user speech, so the next digest starts from the new idle period. Claude uses its user prompt hook, excluding notice hooks. Codex uses a verified turn-end notification whose input array contains no tmux-ask header; an absent array or an older message header does not reset it. No new notes means no digest. It works even when the chip is off. Set the [note digest interval](configuration.md#note-digests) to `0` to disable it.

Send long messages directly. Claude uses quoted heredoc stdin:

```sh
tmux-ask --reply NAME --summary 'Review complete; details retained.' <<'MSG'
Full report, paths and validation results.
Shell syntax such as $HOME stays literal.
MSG
```

Codex uses one quoted multi-line positional argument:

```sh
tmux-ask --reply --summary 'Review complete; details retained.' -- 'Full report with paths.
Validation results and remaining work.'
```

`--summary TEXT` retains the full stdin or positional body for seven days and delivers the summary plus `Read the full message here: tmux-read <id>`. It works for requests, replies, notices and quiet notes. Without it, the message is sent in full. Existing `--message-file PATH` input remains compatible; routine messages need no temporary file.

In Codex code mode, `exec_command` is still a shell tool: JavaScript does not bypass shell parsing or sandbox permissions. Quote shell metacharacters as data and run one tmux command per tool call. If a socket permission denial persists, retry only that command with narrowly escalated permissions.

Copy the exact command in the generated request footer. Codex can answer with `tmux-ask --reply -- "answer"`; Claude uses `tmux-ask --reply NAME` with quoted heredoc stdin. Nameless replies target the latest requester and are safe only with a single open request; otherwise use `--reply PEER "answer"`. Preserve `--any` when supplied. Replies are a message kind, with no request-ID matching. Each delivered header carries an `m…` token to identify that input. Use `tmux-read` only for an explicit pointer; a header token alone has no archived content.

Typing or scrolling delays delivery. `queued` means sent: do not resend. Leaving copy mode or becoming idle allows delivery in order; [configuration](configuration.md) controls idle, copy-mode and attention thresholds. Long waits show `✉`. If the receiver disappears, the message stays saved and the sender is notified; reopening a resumable receiver retries its messages.

Use `tmux-ask --pending` to inspect saved messages and `tmux-ask --retry --to PEER` to retry a live receiver, or omit `--to` for all available receivers. Unavailable destinations stay saved.

Message markers separate agent text from any user draft submitted with it. Agents treat text outside the markers as yours. Keep messages short when possible. When content would flood the receiver's chat, pass the full body with `--summary` as above. Ordinary messages, including file-only sends, are never truncated, split or archived. Retained messages last 7 days even after delivery; requests reuse their request ID, while replies and notices get independent message IDs. Any agent or user in a plain shell can read an ID across socket directories without contacting tmux. Missing or expired IDs produce an error. Read the full text when the summary is not enough. Separate document files are for content that must outlive 7 days or be edited. When relaying a message needing little or no change, add only your own short note and the original pointer line.

## Sub agents

Agents use `tmux-spawn --role ROLE` for chain helpers so configured agents, profiles and model arguments are honored:

```sh
tmux-spawn --role reviewer --name auth-review 'Review src/auth.ts'
```

Use the same direct stdin or quoted positional brief forms as messages. Put positional task text before `-- ARGS` when also passing agent arguments.

### Start a helper

Without `--role` or an explicit agent, helpers inherit the named caller's recorded agent kind and Codex profile, ahead of the calling process's environment. Without a recorded kind, the pinned agent or configured `CODEX_HOME` supplies the default. Plain `codex` uses its default home. Use a bare agent selector only for a user-requested agent override; `--role R WORD` accepts only `claude`, `codex` or configured profiles; other executables use a leading AGENT selector. For other executables, a supplied spawn task is not sent: use the printed full name and resend the actual brief with `tmux-ask` once the agent is at its prompt. See [manual task delivery](agents.md#sending-the-first-task). They open hidden, one window each in a project session such as `agents-api`. Use the full name printed by spawn; [naming rules](#renaming-agents) apply.

`tmux-spawn --role ROLE` selects a role's configured agent, model arguments and name; `--name` overrides the name. A positional agent wins over the role agent and warns when role args are dropped. `-- ARGS` replaces role args; bare `--` clears them. Roles apply only to new helpers, not main or resumed agents. Inspect them with `tmux-agents status` or `tmux-agents chain-config --args --sources`. The new pane records its canonical role in `@role`.

Pass agent CLI arguments after `--`. They follow the flags tmux-agents adds, work with `--split`, `--member` and `--for`, and are saved for `--resume`. On resume, omit `--` to reuse saved args, supply `-- ARGS...` to replace and save them, or use a bare `--` to clear them:

```sh
tmux-spawn --role reviewer --name auth-review -- --model fable
tmux-spawn --role worker --name auth-tests -- --model MODEL
```

`--` now always separates agent arguments; it no longer introduces task text. Put positional task text before `--`, or use stdin. A lone multi-word value after `--` produces a warning when it looks like the former task form; arbitrary positional arguments cannot be identified reliably.

| Spawn option | Effect |
| --- | --- |
| `--mission ID` | Validate the mission first, make the new agent its owner and log `spawned NAME (role)`. |
| `--open` | Open the new agent for the user after spawn. |
| `--plain` | Silence the warning about inheriting an agent instead of selecting a role. |
| `--split PEER` | Place the helper visibly beside a named pane, using the caller's directory. |
| `--right` / `--below` | Choose direction with `--split`; right is the default. |
| `--size N%` | Choose its share with `--split`; default 50%. |

Splits keep the same ownership and depth rules and do not switch your focus. New and resumed Claude/Codex helpers, including members, default to auto permissions. [Set `sub_auto` off](configuration.md) to use agent defaults; this setting does not affect top-level `start`.

After the existing `spawned ...` line, stdout includes `role=ROLE agent=AGENT args="ARGS" source=SRC`, where SRC is `default`, `option`, `chain`, `positional` or `inherited`. Plain spawn prints `role=none agent=KIND args="" source=inherited`. A caller with `@role` or a chain snapshot gets an inheritance warning if it omits both role and agent; `--plain` silences it. `--for` owners are reminded to spawn helpers with `--role`.

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

Names shorten under project headings. Search parts, such as `claude tmux interface`, rather than a full hyphenated name. A hidden agent's bell displays an alert; it alone proves neither completion nor a blocker.

### States and worked time

| State | Meaning and next action |
| --- | --- |
| `⠹ working` | A turn is running. |
| `○ idle` | No task yet, or a top-level turn ended; ready for the next prompt. |
| `✓ done` | A sub agent ended its turn. Its task or background command may still be unfinished. |
| `⚠ permission` | Waiting for approval; open its pane. Auto mode is configurable, not a guarantee against prompts. |
| `◆ needs you` | Explicit user attention or a Claude question/input dialog; inspect its question. An unanswered request alone does not set this state. |
| `✉ message waiting` | Delivery has waited past the attention threshold; finish typing/scrolling, do not resend. |
| `✗ exited` | Process exited; its pane/history remains until closed. |
| `- untracked` | No turn tracking or worked time; messaging still works. |

For a user question or decision, run `tmux-agent-report --needs-you "reason"` before asking. Tracked top-level agents also appear in the default list and status chip while they need you. The reason is shown as activity and survives turn end; ordinary progress or a non-notice turn start clears the attention. Notice-only turns preserve existing needs-you attention.

Done agents show their last report as `done · <text>` in list activity and the status chip. With no report, the list keeps `no report yet` and the chip shows `done`. The list truncates the combined text to its activity column; tmux clips the chip to available status-line space. Stored activity and preview text stay unchanged.

Manual clearing with Claude `/clear` or Codex `/new` is supported. Tracking and `tmux-spawn --resume` follow the newest conversation when its hooks report it. Only a verified Codex thread switch treats its first turn end as current, drops an absent prior delivery token, and leaves any cross-conversation reply obligation unchanged without sending a stop reminder; later notifications retain the normal stale-delivery guard. Existing pane names, members and connections stay in place.

The wrap-up skill owns handoff and resume after a context clear. An agent wrapping up with open sub agents records `tmux-agents status` in the `HANDOFF.md` "Resume steps" section.

Helpers report progress with `tmux-agent-report "running tests"`. This starts work from idle or done. Every ended turn returns to idle or done, including a turn waiting for CI, a background command or another agent. A notice-only turn runs as working from idle or done, but preserves existing needs-you attention. Codex has no turn-start hook: directly typed work may show idle until a report or turn-end notification. Codex runtime approval prompts have no permission hook. Spawned Codex helpers and profiles detect the startup `Folder access` / `Trust this folder?` screen, show `⚠ permission` and notify their parent once that the task has not started. Open the pane and make the trust choice yourself; tmux-agents never confirms it. The permission marker clears when the dialog closes.

A non-working parent shows `waiting on <names>` for its nearest working descendants, including members. The walk passes through idle, done and needs-you agents and stops at each working one. Working parents keep their own report. Counts use each agent's own state. Unrelated and cross-project requests do not appear in this suffix. If a member has stopped, inspect its last report or pane and pick up any finished result.


Compatibility accepts old `--request-id` arguments but ignores their values with a note. Old report `--waiting` and `--local` forms become plain progress; `--local-done` is a successful no-op. Existing archived `r…` IDs remain readable until expiry. This deprecation window lasts at least through the following release; removing the flags needs a separate decision.

`4m · worked 1h5m` means current-state age and total active working time. Permission, needs-you and message waits pause the same turn; idle/done complete it. Pauses and waits after turn end do not count; `turns` counts actual turns. Reopening retains saved work; abrupt removal can lose the uncheckpointed interval. See [accounting](design/state-and-protocol.md#working-time-accounting) and [preview details](design/sub-agents.md#browsing-tmux-agents).

### Close and reopen

Parents dismiss finished helpers with `tmux-dismiss --from ME PEER`; users can close any agent. Dismissal closes descendants first, retaining records. `--keep-children` leaves direct children unowned. `--done` skips members and any subtree containing members or unfinished work. A done helper may still be waiting for its own background command, so inspect its result before cleanup. Parents see closures in `tmux-peers`, without interruption.

Closed conversations remain listed for [7 days by default](configuration.md). `enter` reopens, `ctrl-o` reopens and jumps, `ctrl-x` forgets. Reopening always uses a hidden window, preserving membership and reconnecting to the original parent if still live; otherwise the [resume rules](design/sub-agents.md#closing-and-telling-the-parent) apply.

`tmux-spawn --resume PEER` requires a unique closed match. For duplicate names, use `--list-closed`, then `--resume-id ID`. Resume keeps the recorded agent/profile; records without a kind fall back to the live parent. An explicit agent before the options overrides this choice and is retained for later resumes. Labels may acquire a suffix if taken. Codex must finish a turn before its conversation can be reopened. Saved messages follow the original identity, never another agent reusing its label. Legacy records migrate automatically; see [recovery instructions](design/state-and-protocol.md#recovery).

To resume a closed child in the current shell pane, run `tmux-spawn --resume-id ID --here` from a returned or verified interactive shell. The pane is reused, and its saved parent and membership are restored. A missing parent stays disconnected. The default `--resume` form still opens a hidden window. Claude and Codex print a resume command when their pane returns to the shell; top-level agents use `tmux-agents start`, while sub agents include `--here` to resume in place.

### Members and ownership

| Role | Lifecycle |
| --- | --- |
| Ordinary helper | Task-specific; parent dismisses when finished. |
| `--member` | Long-lived; excluded from default list, ordinary chip counts and done cleanup. `ctrl-a` reveals it; attention still appears. Close explicitly. |

Only top-level callers can create members, including for another owner. Existing agents cannot convert to members; restart the chain.

`tmux-spawn --for PEER "brief"` creates a helper owned by that connected peer, linked only to it and initially idle. The owner receives the brief, introduces itself and sends the first task. Add `--member` for a standing member.

Depth always counts from the caller plus one, including `--for`; default maximum is two. Helpers do not inherit membership. A chain's main creates its interface member at depth 1; interface creates ordinary workers at depth 2, with no further helpers. See [Starting agents](#starting-agents) and the [chain skill](../skills/agent-chain/SKILL.md) for layout and handoff.

## Renaming agents

Suggested names use `<kind>-<dir>-<N>`, with `~` for home. A recognised recorded kind supplies `claude` or `codex` despite launch wrappers; configured Codex profiles use `codex`. Unrecognised kinds or removed profiles fall back to the current command, omitting shell prefixes.

`--name auth-review` adds that kind/directory prefix, keeping an already matching prefix. Spawn suffixes collisions; rename refuses them. Prefixed mode sanitises characters; exact mode validates them. See [character rules](design/state-and-protocol.md#naming) and [configuration](configuration.md).

`tmux-rename --from ME PEER main` renames yourself or a descendant; the user can omit `--from` to rename any agent. `--exact` keeps the supplied name verbatim. The agent and peers receive notices. Use the printed full name thereafter; old names have no aliases. IDs, ownership, queued messages and history survive. Only live labels must be unique. `tmux-connect --as NEW` also renames, keeping its verbatim-name behaviour.

## More than one Codex account

Configure existing homes with the [Codex profiles recipe](configuration.md#codex-profiles), then rerun the installer for their skills and rules. `tmux-agents start work` launches a tracked top-level agent; `tmux-spawn work "task"` launches a helper whose children inherit that profile. Optional [shell wrappers](../integrations/sh/codex.sh) pin identity only.

## Check Codex command access

After a Codex CLI upgrade and before releases, run the local [Codex compatibility probe](../ci/README.md#real-codex-compatibility-probe) against the configured homes and rules. By default, `ci/codex-probe.sh --profile codex-2nd` tests this checkout's `bin/`; use `--installed` after updating the installed copy. It starts a fresh `codex exec` session on a private tmux server and prints model results alongside independently checked command effects. Select the CLI with `--binary`, the model with `--model`, or the per-profile runtime with `--timeout`. This requires real Codex authentication and may need network access; it is not run in CI.

The probe uses `codex exec` (originator `codex_exec`). Agents launched by `tmux-spawn` use the interactive Codex TUI, whose available tool surface can differ; the probe does not cover TUI-specific behavior.

## Commands

Agent commands below use actual names for `ME`/`PEER`. See each command's `--help` for full syntax.

| Command | Purpose |
| --- | --- |
| `tmux-agents start AGENT [-- AGENT ARGS]` | Launch an independent agent; Claude/Codex have tracking. |
| `tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--main-resume ID] [--interface AGENT] [--worker AGENT] [--designer AGENT] [--reviewer AGENT] [--runner AGENT] [--researcher AGENT]` | Start a chain in a new window. |
| `tmux-agents chain [DIR]` | Pick or launch a project chain. |
| `tmux-agents main-sequence` | Open or edit configured project windows. |
| `tmux-connect [target] [--as NAME] [--all]` | User's connection picker or direct target. |
| `tmux-connect --from ME TARGET` | Agent connection by type, name or pane. |
| `tmux-rename --from ME PEER NAME [--exact]` | Rename yourself or a descendant. |
| `tmux-disconnect [name]` | User unlinks one peer or all. |
| `tmux-peers [--ids] [--me]` | Show identity and connections; `--me` prints just your name. |
| `tmux-ask [--any] [--reply\|--notice\|--note] [PEER] [--summary TEXT] [msg...]` | Send a direct positional/stdin body; summary retains full text behind a pointer. Nameless replies use the latest requester; use only with one open request and put `--` before a positional body. `--any` permits unlinked targets. |
| `tmux-notes [--all] [--since 10m\|2h] [--keep-unread] [--count]` | Read quiet notes; default reads and marks unread entries, while `--count` only counts unread notes. Bare `tmux-notes --count` is the fast statusline form using `$TMUX_PANE`. |
| `tmux-read ID` | Read any retained message by ID (7-day retention; no tmux connection needed). |
| `tmux-ask --pending` | Inspect queued/undelivered messages. |
| `tmux-ask --retry [--to PEER]` | Retry saved messages. |
| `tmux-peek PEER [lines]` | Read peer output; default 40 lines. |
| `tmux-shell [--from AGENT] [--client CLIENT] [--pane OPENER]` | Open an independent or explicitly owned shell popup. |
| `tmux-spawn [AGENT] --role ROLE` | Spawn using configured role agent, args and name. |
| `tmux-agents chain-config [ROLE] [--args] [--sources]` | Inspect role settings; `secondary` aliases `interface`. |
| `tmux-spawn --role ROLE [--member] [--mission ID] [--open] [task]` | Spawn with a positional or stdin brief; also accepts `--name`, `--split` and `--for`. |
| `tmux-spawn --list-closed` | List saved conversations. |
| `tmux-spawn --resume PEER` / `--resume-id ID [--here]` | Reopen a conversation, optionally in the current shell pane. |
| `tmux-agent-report [--needs-you] [--mission ID] "text"` | Report progress or user attention; optionally log mission progress. |
| `tmux-agents status [--notes] [--handoff] [--missions full] [PEER]` | Orient or inspect a peer; `resume` is an alias. |
| `tmux-agents chain-config set ROLE AGENT [-- ARGS]` | User or main only; Codex prompts. Update live defaults and print tmux.conf lines; args are space-separated without quoting. |
| `tmux-agents ci [--watch] [REF]` | Summarize checks for a commit, optionally waiting. |
| `tmux-agents` | Open the agent list. |
| `tmux-dismiss --from ME PEER` | Close a descendant and its subtree. |

### Standard input by command

| Command | What it reads | Agent message file? |
| --- | --- | --- |
| `tmux-ask` | User-authored message body when no positional text is supplied. | Legacy file input remains supported; prefer direct bodies. |
| `tmux-spawn` | User-authored task/brief when no positional task is supplied. | Legacy file input remains supported; other executables still need manual `tmux-ask` delivery. |
| `tmux-agent-report` | Hook payloads, including Claude hook JSON and progress/notification protocol data. | No. This is protocol input, not a user message. |
| `tmux-connect` | Interactive numeric selection and key input. Other reads are generated row pipelines. | No. This is interaction, not a message body. |
| `tmux-dismiss` | Confirmation is read from `/dev/tty`, not caller stdin. | No. |
| `tmux-agents` | `fzf` selection input comes from generated rows; keypresses use the terminal. | No. |
| `tmux-shell` | Popup metadata comes from an internal here-string. | No. |
| `tmux-shell-history` | Internal history files and shell-history subprocess output; interactive confirmation is terminal input. | No. |
| `tmux-shell-run` | Interactive keypresses from the terminal. | No. |

## Slow popup startup

Slow shell initialization can delay popups before tmux-agents runs. See [performance diagnostics](performance.md) to measure startup and keep interactive setup out of non-interactive shells.

## Project missions

Trusted panes infer the author and default owner. Supply `--from NAME` for unpinned
Codex or offline use without a running tmux server, as in these examples:

```sh
tmux-agents mission add "Build mission board" --from my-agent --status design
tmux-agents mission set M1 --from my-agent --status active --branch feat/board
tmux-agents mission log M1 "Layout approved" --from my-agent --kind decision
tmux-agents mission show M1 --from my-agent --log 5
tmux-agents mission list --from my-agent --all --tsv
```

`add` prints the allocated ID. `set` changes title, owner, status, branch or worktree;
status changes also append a progress log. `log` accepts progress (default), decision,
handoff or done. Statuses are design, plan-ready, active, needs-decision,
ready-to-push and done. `list` hides done missions unless `--all` is supplied. TSV
columns are id, status, owner, title, branch, worktree, created and updated, without
a header. `show` includes fields and the last five log entries by default.

Records live in `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/missions/PROJECT/`,
using the main repository's name across linked worktrees (or the directory name
outside Git, with `home` for the home directory). Updates preserve unknown record
fields and publish records atomically. Writers use a directory lock; a busy or stale
`.lock` produces an error after two seconds of retries. Remove a stale lock only after verifying no writer remains.
Title, owner and log text must be nonempty; `set` requires at least one field.
Values cannot contain tabs or line breaks. For text starting with `--`, put all
options first, then `--` and the positional arguments, for example:
`tmux-agents mission add --from my-agent -- "--flag documentation"`.
Lists use numeric ID order; allocation also reserves IDs with surviving log files.

## Mission board

Run `tmux-agents board` to print the current project's missions and live agents,
or `tmux-agents board --watch` to keep a pane updated every two seconds.
`--watch SECS` changes the interval (positive whole seconds); press `q` or Ctrl-C
to quit. Press `a` to toggle earlier done missions immediately, including their
completion outcomes; `--all` starts expanded. A dim footer shows the keys, also
visible without colour under `NO_COLOR`. The view adapts to the pane width and shows how long ago each mission
was updated. Watch retries after a failed refresh; configuration and project
path lookups are cached for the lifetime of the command. Every refresh prints
the full board on the normal screen regardless of pane height; use tmux copy-mode
to scroll. Each refresh clears the previous screen and scrollback, so history
contains only the current board; scrollback from before `--watch` started is cleared too. Quitting restores the cursor and terminal input settings.

Terminal output uses colour unless `NO_COLOR` is nonempty; piped output stays plain.
Working glyphs animate in watch mode at `@tmux_agents_chip_fps` (default 10,
clamped to 1..30); boards that fill or exceed the pane height advance only on
data refresh, so ticks never scroll the pane. Missions appear newest
created first, and sibling agents sort by attention state, then working, idle
and done, keeping pane order for ties.

Missions come from `${XDG_STATE_HOME:-~/.local/state}/tmux-agents/missions/<project>/M<N>.mission`,
one `key=value` record per mission. Required keys are `id`, `title`, `owner`,
`status`, `created` and `updated`; timestamps are epoch seconds. Optional `branch`
and `worktree`, and unknown keys, do not affect the view. Use the owner's full
agent name. Each mission shows its live owner and descendants, including kind,
saved `--model` (or `default`), state and latest progress. Other live project
agents appear under `unassigned`, which is hidden when empty. The project main
(`@role main`) and its subtree appear first under `pinned`; agents are shown only
once. A descendant owning a displayed mission appears with its subtree under that
mission, rather than under pinned. Owners of folded done missions stay pinned
until those missions are expanded. Names omit the agent and project prefix unless that would be ambiguous.

Done missions show the last `done` log text as a dimmed outcome line, when present.
Only the three most recently completed missions are expanded by default; earlier
ones are folded into a count and ID list. Completion log timestamps determine
recency, falling back to the mission update time when no completion exists.
`--all` expands every mission and can be combined with `--watch`. An unfinished
mission whose owner is no longer live shows a highlighted `owner gone` line with
the latest log text, when present. `open` requires a live pane, so the board does
not offer it for absent owners. All lines fit the pane width.

Linked worktrees use the main repository's
mission records. Live descendants stay in their project's tree when their working
directory changes. A missing directory or missing records still
shows live agents. The legacy `board.md` is ignored; no mission CLI is needed.
