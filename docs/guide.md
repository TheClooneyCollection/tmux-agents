# tmux-agents guide

The details behind the [README](../README.md). Design notes and pitfalls are in [DESIGN.md](../DESIGN.md).

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

## Connecting agents

1. Open a pane and start `claude`.
2. Open another pane and connect it before starting Codex:
   ```sh
   tmux-connect --as codex   # pick the claude pane from the list, name it "claude"
   codex
   ```
3. Tell either agent to talk to the other: "ask codex to review this diff".

Or skip connecting by hand: tell an agent "connect codex and have it do xyz". It runs `tmux-connect --from <itself> codex`, which finds the other pane in this window running codex, names both panes if needed, and links them; then it sends the task.

Both agents already running? Press `prefix + A` in one pane to connect it from a popup. It lists this window's panes with a preview; `ctrl-a` switches to every window, grouped by window, and is remembered.

**Agents in other windows.** Tell an agent "connect the codex in stone-age" or "connect the claude in window 2". It runs `tmux-connect --from <itself> codex@stone-age` (a project, by name or part of it) or `claude@2` (a window; `work:2` for another session). For anything vaguer it lists every pane with `tmux-connect --list` and picks the one you mean, or asks. The agent in the other window gets a short notice saying who connected, since it didn't see it happen.
Add more agents the same way. Links are one-to-one: A↔B and B↔C does not link A↔C.

Connected panes show `name ⇄ peers` on their top border, e.g. `claude ⇄ codex, gemini`.

Suggested names are `<command>-<dir>-<N>`: `claude-project-xyz-1`, `claude-~-1` in home, then `-2`, `-3`... Both panes are named in one form: ↑/↓ to switch, type to edit, Enter to accept.

## Renaming agents

Use `tmux-rename <agent> <new>` to rename a live agent. For example, `tmux-rename codex-~-1 main` produces `codex-~-main`; a matching prefix is kept, and `--exact` keeps the supplied name verbatim. Agents pass `--from ME` and may rename themselves or descendants, never peers or ancestors. The user may rename any agent without `--from`.

Renaming changes the live label and the label in its own session record, preserving its stable agent ID, parentage, queued message destinations and history. The agent and its peers receive notices, queued when busy. Use the new label in later commands, including `--from`; the old label has no alias. Only live names must be unique, so labels held by closed agents are free to reuse. `tmux-connect --as NEW` on a named pane uses the same rename helper but keeps its verbatim-name behaviour.

## Sub agents

Agents start sub agents with `tmux-spawn` instead of their built-in ones, so every sub agent has a real pane with its full history.

```
claude:  tmux-spawn --name auth-review "review src/auth.ts"
         → new hidden window "claude-<dir>-auth-review" in session agents-<project>
         → starts claude with the task, connected to the caller
claude-<dir>-auth-review:  ...works, then tmux-ask --reply back to the caller
```

- **Long-lived members.** Use `tmux-spawn --member` for a standing team member; it works with `--split` and `--for`. Only a top-level caller (no `@parent` and no `@member`) can spawn members. This checks the caller, not the `--for` owner, so main can give a member another member. Members keep their owner, so explicit dismissal still closes the whole subtree. They stay out of the default sub-agent list and ordinary chip counts; `ctrl-a` shows them in their project with `member of <owner>` in PARENT. `--done` and `ctrl-d` never close members, including through an ancestor. Attention still pins them in the list and chip. Closed members share the closed section, and resume preserves membership. Existing agents cannot be converted; restart an existing chain to use members.
- **Names.** `--name auth-review` becomes `<kind>-<dir>-auth-review`, using the new agent's kind (`claude` or `codex`, including Codex profiles) and directory (`~` for home). An existing matching prefix is kept; clashes get `-2`, `-3`... Use the name the command prints, including any suffix. In prefixed mode, spaces and characters outside letters, digits, `.`, `_`, `~` and `-` become `-` before prefixing; capitals are preserved (`Auth Review` becomes `codex-<dir>-Auth-Review`). Exact mode refuses invalid characters rather than changing them. `--exact` keeps a given name verbatim; see [Configuration](#configuration) for a standing preference.
- **Hidden by default.** Each project gets its own session (`agents-api`, `agents-blog`), one window per sub agent. Nothing is added to your layout.
- **Easy to check.** `prefix + a` opens `tmux-agents`: your sub agents with status, parent, project, what they're doing now, and a preview that refreshes twice a second. Statuses use the chip's colours (red `⚠ permission`, amber `◆ needs you`, `⠿ working`, green `✓ done`, grey `✗ exited`), and the ones that need you sort to the top. The keys are shown in a footer.
  - `enter`: open a hidden agent in a popup, where you can approve prompts. `prefix + d` takes you back to the list, on the same agent. Visible panes are jumped to instead.
  - `ctrl-o`: jump there full screen; `prefix + L` jumps back. `ctrl-x`: dismiss. `ctrl-d`: close every `done`/`exited` sub agent after a y/N confirmation. `ctrl-a`: toggle between sub agents and every named pane (remembered for next time). `ctrl-t`: toggle this window / all windows (starts on this window each time). `ctrl-r`: refresh. `prefix + d`: close the list (it also leaves an agent's popup, so pressing it twice gets you all the way out).

- **List layout and time.** Names occupy 26 display cells. Under their own project header, `claude-my-project-review` becomes `claude·review`; longer labels keep their start and end around `…`. Parents in the same project use the same abbreviation. Pinned rows keep the project prefix because their header does not name the project. The activity line is shortened by display width, including double-width CJK characters, before the status column. Closed rows use that space for the project.
- **Searching.** The list searches the displayed short name and project. A full hyphenated name pasted in order, such as `claude-tmux-agents-secondary`, will not match because the display order and `·` separator differ. Search its parts instead: space-separated terms match in any order, for example `claude tmux secondary`.
- **Worked time.** The status detail reads, for example, `4m · worked 1h5m`: time in the current state, then accumulated working time. Idle, done, permission, needs-you and message-waiting time do not count. Permission, needs-you and message waits pause the same turn; the last-turn value includes all its working intervals, excluding pauses. Turn completions and pauses save accrued work; reopening preserves it and adds subsequent work. Abrupt pane removal can lose the active interval, but keeps previously saved work. The preview shows the full name, activity wrapped to its width in a fixed three-line area (truncated with `…`, padded when short), start time, age, total worked, last turn and turn count. The seven-line header stays pinned while pane content follows its tail, with a dim separator between them. Closed agents show their last saved activity when available. Agents from before the upgrade show `started ?`; no past work is reconstructed, and an unknown total omits the worked part.

- **Status chip.** While sub agents exist, a line above the status bar shows them:

  ```
        ⠹ auth-review: reading src/auth.ts  │  api ⠹ 2 ✓ 1 · blog ⠹ 1
  ```
  Centred: one agent in focus, rotating every 4s, then per-project counts (`⠹` working, `○` idle, `✓` done, `⚠` needs permission, `◆` needs you, `✗` exited). An agent waiting for permission (red) or for you (amber) takes over the focus, and blinks after 60s unanswered. **Needs you** means a sub agent ended its turn without replying to its parent and without waiting on anyone or anything (its own sub agents, requests it sent, work it reported with `tmux-agent-report --waiting`, a progress notice it sent to its parent, or, for Claude, Bash commands still running in the background), which is how a Codex sub agent asks you for something (it never gets approval prompts, see [sub agents](design/sub-agents.md#data-not-screen-scraping)). The line disappears when no sub agents or panes needing attention remain. It animates at `@tmux_agents_chip_fps` frames a second (default 10, set after the `source-file` line to change it); `1` falls back to tmux's once-a-second refresh.
- **Window scope.** The list uses the window of the client it was opened for. A pane belongs if it or any ancestor in its `@parent` chain is there, including hidden children and grandchildren. Both views follow this scope. Returning from a hidden agent's popup keeps the scope and selected agent; an empty window still offers `ctrl-t` to show all windows. Closed agents follow session records through closed parents to a live ancestor and its visible window; all-window scope includes records whose parent is gone.
- **Pinned attention.** Every sub agent or member waiting for permission or marked `needs you`, plus any pane with `✉ message waiting`, appears first, even from another window, longest wait first. Its second line gives the owning window (`session:index`), project and activity. Hidden agents use the first visible ancestor's window; splits use their own, and a missing or entirely hidden ancestry falls back to the agent's own window. It appears only once. The status-bar chip stays global.
- **Progress reports.** Sub agents report what they're doing with `tmux-agent-report "<a few words>"`; permission waits are reported by hooks. Nothing is read off the screen.
- **Idle.** A sub agent spawned without a task, including `--for`, starts as grey `○ idle` in the list and chip. Its first request or progress report starts work; ending an idle turn never flags it as needs you.
- **Done.** A sub agent is `done` once it replies to its parent, and `running` again when it gets a new request. So a parent that only wants to tell its sub agents something (a rule change, "carry on") sends a notice (`tmux-ask --notice`), which needs no reply. A request saying "no reply needed" still makes the parent wait for one, and the sub agent shows as needs you once it ends its turn without replying.
- **Waiting for work.** Use `tmux-agent-report --waiting "<reason>"` before ending a turn to wait for background work or another agent. A progress notice to your own parent also keeps the turn working. A normal report or a new request clears the wait; replying to your parent marks you done. Never use these to hide a question for the user.
- **Long answers.** Agents reply with a short summary and a path to the full report in a temp dir. `tmux-ask` also saves any message over 60 lines to `$TMPDIR/tmux-agents/<sender>/` and sends the first 15 lines plus the path.
- **Alerts.** When a hidden agent rings the bell (e.g. waiting for approval), your status line says `agent <name> needs you`.
- **History is kept** until someone closes it. Panes stay after the agent exits. The parent closes its sub agents once it has what it needs (`tmux-dismiss --from`, any descendant); you can close any of them. Closing removes the whole subtree deepest first and lists every closed agent, retaining each session record. `--keep-children` closes only the target and leaves its direct children unowned. `--done` skips members and any subtree containing a member or an agent still working or waiting.
- **Parents learn about your closes.** When you close a sub agent, its parent isn't interrupted. Its `tmux-peers` lists it under `closed by user`, and a later `tmux-ask` says it was closed instead of failing with "no pane".
- **Reopening.** The list retains closed agents for 7 days by default (`@tmux_agents_resume_days`). In its `closed` section, `enter` reopens the selected conversation connected to its old parent, `ctrl-o` reopens and jumps there, and `ctrl-x` forgets it. Same-named records show their closed time, parent and project; rows never show IDs, though the right preview may. `tmux-spawn --resume <name>` reopens the unique closed match. If several match, it refuses and lists them; use `tmux-spawn --list-closed` and `tmux-spawn --resume-id <id>` to select the intended conversation. The reopened agent keeps its ID and gets a `-2`, `-3` suffix if its label is already live. A Codex agent needs to have finished a turn so its conversation ID is recorded.
- **Stable identity.** Connect, message, peek, rename and dismiss live agents by name as before; only `--resume-id` requires an ID. `tmux-peers --ids` exposes IDs to agents and scripts. Reusing a closed label creates a different identity, preserving the closed conversation and its children. Saved messages follow the original ID when it reopens, not a new agent with the same label. Existing records migrate automatically on the first command that needs them; conversation IDs and parent relationships are retained.
- **Migration backup.** Before the first rewrite, original record files are copied once to `sessions/.pre-ids-v1/` under `${XDG_STATE_HOME:-~/.local/state}/tmux-agents/<server>/`. This backup is retained and never replaced by later runs. To recover the old records, preserve a separate copy of the backup, stop that tmux server and use the previous version with the backup files restored into a clean sessions directory. Do not overlay old records or remove the migration marker while the server is running. The backup covers session records, not live pane state or message queues. Only this server's queue directory is migrated; shared flat-root legacy files remain untouched.
- **Same kind by default, in auto mode.** Claude spawns Claude, Codex spawns Codex, and a Codex on another account spawns on that account. Sub agents start with Claude's `--permission-mode auto` or Codex's `approvals_reviewer="auto_review"`.
- **Depth limit.** At most two levels (`TMUX_AGENTS_MAX_DEPTH`). Every new sub agent or member uses the caller's depth plus one, including with `--for`, and the normal limit applies to both. Helpers do not inherit membership.
- **Visible layout.** When you want sub agents in the same window, use `--split <name-or-pane-id>`: `--right` (default) places the new pane to the right, `--below` beneath it, and `--size N%` sets its share (default 50%). Splits stay detached, use the caller's directory, and keep the same ownership, depth, records and status chip. Enter in the agent list jumps to a visible split; `tmux-dismiss` closes its pane and descendant panes, leaving unrelated panes intact. Without `--split`, sub agents open hidden as before.

  For a chain with main left, secondary top right and worker bottom right (set `main` to the existing main agent's full name):
  ```sh
  tmux-spawn claude --from "$main" --member --split "$main" --right --name secondary "coordinate the work"
  # Set secondary to the full name printed above before running this.
  # codex-work is an example profile from @tmux_agents_codex_homes (a second
  # Codex account); use codex for your default account.
  tmux-spawn codex-work --from "$main" --member --for "$secondary" --split "$secondary" --below --name worker "implement the task"
  ```

  `--right`, `--below` and `--size` require `--split`. A closed split always reopens in a hidden window with `--resume`; move that pane into your layout if wanted.
- **Spawning for another agent.** `tmux-spawn --for <owner>` gives an agent you're connected to a sub agent of its own: it belongs to `<owner>` (connected to it only, listed under it, reports to it) and starts without a task. You tell `<owner>`, with your brief, and `<owner>` introduces itself and sends the first task. For both sub agents and members, depth counts from the caller plus one. A top-level main spawns the chain's secondary and worker at depth 1; the worker's helpers are depth 2. See [the decisions](decisions/README.md).

## Commands

| Command | What it does |
| --- | --- |
| `tmux-connect [target] [--as NAME] [--all]`, `tmux-connect --from ME codex\|claude\|NAME` | Name this pane and link it to `target` (name, `%id`, or `1.0`). No target opens a picker of panes in this window (`--all`: every window); the pane under the cursor is tinted. Unnamed panes get asked for a name. With `--from` (agents) it never prompts: `codex`/`claude` picks that agent's pane in this window, and names are generated. |
| `tmux-rename [--from ME] <agent> <new> [--exact]` | Change an agent's label, keeping its ID. With `--from`, yourself or descendants only. |
| `tmux-disconnect [name]` | Unlink from `name`, or from everyone. |
| `tmux-peers [--ids]` | Show this pane's name and its connections; optionally include stable agent IDs. |
| `tmux-ask [--from ME] [--any] <name> [--reply] [msg]` | Paste a message into a connected pane and submit it. Reads stdin if no `msg`. `--any` sends to any named pane, connected or not. |
| `tmux-peek <name> [lines]` | Print the last lines (default 40) of a connected pane. |
| `tmux-spawn [claude\|codex\|PROFILE] [--name NAME] [--exact] [--member] [task]` | Start a connected sub agent (or long-lived member with `--member`) hidden, or visibly with `--split NAME`, and send it the task (or stdin). Given names get the kind-directory prefix unless `--exact`; taken names get `-2`, `-3`... |
| `tmux-spawn --list-closed`, `--resume NAME`, `--resume-id ID` | List saved conversations or reopen a unique name or exact ID. |
| `tmux-agent-report [--from ME] "text"` | Report what a sub agent is doing, for the chip. |
| `tmux-agents` | Browse this window's sub agents; `ctrl-a` selects every named pane, `ctrl-t` selects all windows (`prefix + a`). |
| `tmux-dismiss [--from ME] <name>` | Close an agent and its subtree. With `--from`, descendants only. `--keep-children` retains direct children as unowned. `--done` closes only wholly done/exited subtrees with no members after a y/N. |

## How messages flow

```
claude:  tmux-ask codex "review src/auth"      → pasted into codex's pane
codex:   ...works, you approve its prompts...
codex:   tmux-ask --reply claude <<'MSG' ...   → pasted into claude's pane
```

- Requests say who sent them, who they're for, and the exact reply command (with `--from <receiver>`). Replies say not to answer back, which stops loops.
- Nobody waits. The sender ends its turn, and the reply arrives later as a new prompt.
- **You typing wins.** If you pressed a key in the receiver's pane within the last 8 seconds, or are scrolling it (copy mode), the message is queued. It goes out as soon as you leave copy mode (mouse or keys), or after 8 quiet seconds if you were typing. A pane left in copy mode for 5 minutes without a key is taken out of it so the message goes through (`TMUX_ASK_COPY_IDLE_SECS`, `0` to turn it off). Queued messages keep their order. After `TMUX_ASK_QUEUE_SECS` (30 minutes), `✉ message waiting` appears in amber in the list and chip; a live receiver keeps its queued messages until delivery. If the receiver disappears, the sender gets a delivery failure notice with the saved `.undelivered` path. If both are gone, clients get a status-line message. A resumable receiver gets its saved messages when reopened, oldest first.
- **Inspect and retry.** `tmux-ask --pending` lists queued and undelivered messages, including legacy files. `tmux-ask --retry --to NAME` retries saved messages for a receiver that exists now; omit `--to` to retry all available receivers. Messages that cannot be placed stay saved.
- **Messages are fenced.** Every message ends with `[end of request/reply from X to Y]`. If a draft of yours gets submitted along with one, the agent treats the text outside the markers as yours.
- If an agent is busy, Claude and Codex queue the pasted message themselves.

## How it works

State lives on the panes as tmux user options, with no files:

- `@agent`: the pane's name, unique across the tmux server.
- `@peers`: pane ids it links to.
- `@parent`: on sub agents and members, the owner pane (the `--for` target when given).
- `@member`: `1` for a long-lived member; saved as `member=1` in its session record.

Pane ids survive moving panes between windows. Closing a pane drops its links.
Inspect with `tmux show -p @agent` / `tmux show -p @peers`.

Agent-facing commands take `--from <name>` to say who is acting. Codex runs commands in a shared daemon whose `$TMUX_PANE` may be another pane, so agents always pass it; see [the shared daemon](design/environment.md#codex-runs-commands-in-a-shared-daemon).

`TMUX_ASK_ENTER_DELAY` (default `0.5`) sets the pause between pasting and pressing Enter. Raise it if a TUI drops the Enter.
`TMUX_CONNECT_HIGHLIGHT` (default `bg=colour24`) sets the picker tint.
`TMUX_AGENTS_MAX_DEPTH` (default `2`) limits sub agent levels.

## More than one Codex account

List extra Codex homes as `name=path` pairs, then run `install.sh` again so they get the skill and rules too:

```sh
export TMUX_AGENTS_CODEX_HOMES="work=$HOME/.codex-work"
```

Putting the same line in `~/.tmux.conf` also works, and reaches agents that were already running when you set it:

```tmux
set-environment -g TMUX_AGENTS_CODEX_HOMES "work=$HOME/.codex-work"
```

`tmux-spawn work "task"` starts a sub agent on that account, and a Codex started with `CODEX_HOME=$HOME/.codex-work` spawns `work` sub agents by default. Give it its own wrapper; `integrations/sh/codex.sh` shows one.

## Slow popup startup

Tmux launches popup commands through its `default-shell`. Slow non-interactive shell startup delays the popup before tmux-agents runs. Check with `time fish -c true` (or your configured shell). In fish, keep interactive-only initialization, such as prompt helpers, inside `if status is-interactive ... end`. The agent list draws its prompt first and loads rows asynchronously.
