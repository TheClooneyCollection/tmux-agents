# State and protocol

Part of the [design notes](../../DESIGN.md).

## State lives on panes

Live state uses tmux user options on the panes (`set-option -p`); session records and message metadata retain identity after panes close:

| Option | Meaning |
| --- | --- |
| `@agent` | The pane's label, unique among live agents on the tmux server. |
| `@agent_id` | Stable agent identity: `a` plus 12 random hex digits. A reopened agent keeps it. |
| `@peers` | Space-separated pane ids (`%12`) this pane links to. |
| `@peer_names` | Cached `name, name` string for the border label. |
| `@parent` | On spawned sub agents and members: the owner pane id, including the `--for` target. |
| `@member` | `1` for a long-lived member; persisted as `member=1` in its session record. |
| `@closed` | Agent IDs of peers the user closed (set by `note_closed` before `kill-pane`), rendered as labels. |
| `@state` | On sub agents: `idle`, `done`, `working` or `needs_you`. See [done state](sub-agents.md#done-state-and-cleanup) and [chip data](sub-agents.md#data-not-screen-scraping). |
| `@msg_waiting_since` | Epoch when a queued message began waiting; set after the escalation threshold and cleared on delivery. Pins the receiver in the list and highlights it in the chip. |
| `@awaiting` | Agent IDs this pane sent requests to and hasn't had a reply from yet, rendered as labels. |
| `@activity`, `@waiting_on`, `@perm_since` | Sub agent reports for the [status chip](sub-agents.md#status-chip). |
| `@attention_since`, `@codex_thread` | When a sub agent started needing the user; the Codex thread id of a sub agent, for `notify`. |

Windows that hold named panes also get `@agents_border=1`, plus window-level `pane-border-status top` and `pane-border-format`. The marker lets `refresh_labels` undo only the border settings it set itself.

Why pane options:

- **Stable ids.** Pane ids survive moving panes between windows and sessions.
- **Automatic cleanup.** Closing a pane deletes its options. Other panes' `@peers` still list the dead id until `get_peers` prunes it on the next read.
- **Live links are local.** `tmux show -p @peers` shows current connections. Durable queue files and session records separately retain messages and closed conversations.

## Links

- Links are one-to-one and symmetric. `tmux-connect` writes both sides.
- They are not transitive: A↔B plus B↔C does not link A↔C, so the user always knows who can reach whom.
- `tmux-ask` and `tmux-peek` refuse unlinked targets (`resolve_peer`). `tmux-ask --any` skips the check and resolves any named pane; the request's reply instructions carry `--any` so the receiver can answer. The receiver must have a name.

## Naming

- `suggest_name` builds `<command>-<dir>-<N>`:
  - `dir` is the cwd basename, or `~` for `$HOME`.
  - Shells (`fish`, `zsh`, `bash`, ...) are left out of the prefix, because a pane about to start an agent still reports its shell.
  - `N` is one past the highest number in use with that prefix. Gaps are not reused.
  - Extra arguments count as taken, so two suggestions made in the same run don't collide.
- `sanitize_name` maps anything outside `A-Za-z0-9._~-` to `-`.
- `set_name` names an unnamed pane and refuses names held by another pane. Existing identities change through `rename_agent`, including `tmux-connect --as`.
- `format_given_name` is shared by spawn and rename. It sanitises short names and adds the command/directory prefix unless the name already has it; exact mode validates without sanitising; `--exact` wins over `TMUX_AGENTS_NAME_FORMAT`, then `@tmux_agents_name_format`, then the `prefixed` default. Spawn uses the new agent's kind (`codex` for a Codex profile), then adds a unique suffix if necessary. Rename refuses collisions with live labels; closed labels may be reused.
- `tmux-rename --from ME` authorizes self or descendants through pane-id ancestry; without `--from`, the user may rename any agent. It changes `@agent` and its own record's `name=`, refreshes labels, and sends durable notices from `tmux-rename` to the agent and its peers. Its ID and all references remain unchanged. Old labels stop resolving immediately; there are no aliases.
- **Checked step by step.** `auto_name` runs inside `$(...)`, where `set -e` doesn't apply, so it returns failure explicitly when `set_name` fails, and every caller dies on it. Checking a name and writing it isn't atomic, so after writing it confirms no other pane holds the same name; otherwise it clears its own and retries with the next number after a short random pause.
- **Unnamed panes name themselves.** A freshly opened agent has no `@agent`. When its `$TMUX_PANE` can be trusted (Claude, or Codex with `TMUX_AGENTS_PINNED`), `tmux-ask`, `tmux-peers`, `tmux-spawn`, and any command given an unknown `--from` give that pane a generated name (`auto_name`) and print it, so the agent can carry on with it. This came up when an unnamed Claude copied `--from claude` from the skill's example and `tmux-spawn` failed on `no agent named 'claude'`; the examples now use a placeholder. Unpinned Codex still gets an error, since its `$TMUX_PANE` may be another agent's pane (see [environment](environment.md#codex-runs-commands-in-a-shared-daemon)).

## Durable agent identity

An agent gets `@agent_id` when first named, including auto naming, connecting, spawning and renaming an unnamed pane. Pane IDs still identify live links; agent IDs identify a conversation across pane closure and reopening. Live labels remain unique, but closed labels need not be.

Session records live at `sessions/<agent-id>`. `agent_id=` explicitly marks the new format, `name=` holds the label, `parent=` holds a parent's agent ID, and `parent_name=` is a display fallback. `id=` remains the Claude/Codex conversation ID, not the agent ID. Lookup by label may return several saved records, so resume-by-name must refuse ambiguity; `--resume-id` chooses one record. Reopening preserves the agent ID and conversation ID, using a suffix if its label is already live.

On the first command needing identities, `ensure_agent_ids` migrates legacy state under the exclusive identity lock, before message commands take their shared lock. It assigns missing live IDs, rewrites name-keyed records with preserved conversation IDs and parent relationships, and converts `@awaiting`, `@closed` and this server's queue metadata references. Flat-root legacy queues are never rewritten because their server identity is unknown. Before any rewrite, it saves the original record files once in `sessions/.pre-ids-v1/`, retained for recovery. Unresolved parent labels remain in `parent_name=` without a guessed ID. Replacement records are written before legacy files are removed; `sessions/.ids-v1` marks completion, and rerunning migration is idempotent. The library does no migration just by being sourced, preserving the picker's early first frame.

## Configuration lookup

`settings_load` lazily reads the global `@tmux_agents_*` options in one `tmux show-options -g` snapshot per shell, decoding quoted values as data rather than evaluating them. `settings_get OUTPUT ENV OPTION DEFAULT` assigns in the caller's shell, preserving the cache and choosing a non-empty environment override before the option and default. Derived values remain shell variables, not exported overrides. Spawn retains the extra Codex homes global-environment fallback and passes its resolved account map across the startup boundary in a temporary internal variable.

The initial picker does not load settings before fzf draws. List, chip and preview paths load what they need when they run; `list-budget.sh` counts the parser as well as tmux calls. See [Configuration](../guide.md#configuration) for the complete table.

## Connecting

### Picker and popup (the user)

- The picker lists panes in the current window, or every window with `--all` or after `ctrl-a`, which stores `@tmux_connect_scope` so the next picker opens the same way. Entries look like the agent list's: two lines (name, command, project, whether it's already linked; then what it's doing or its directory), in a section per window, this window first and hidden `agents-*` sessions last. `connect_tsv` builds the rows for both the picker and `--list`. A preview shows the focused pane, since the tint can't be seen in another window.
- It dedupes by pane id, because grouped sessions list a shared window once per session.
- fzf's `focus` event runs `tmux-connect --highlight <id>`, which sets pane-level `window-style` (`TMUX_CONNECT_HIGHLIGHT`, default `bg=colour24`) on the focused pane and clears it on the other candidates. The `EXIT` trap clears it on pick, cancel and error.
- `tmux-connect` names every unnamed pane in one form (`name_form`): ↑/↓/Tab switch fields, typing appends, Backspace deletes, Ctrl-U clears, and one Enter accepts all. Without a TTY it reads one line per field, which the tests rely on.
- The `prefix + A` binding is:
  ```
  bind A run-shell -b "tmux display-popup -c '#{client_name}' -E ... '$HOME/.bin/tmux/tmux-connect --popup --from #{pane_id}'"
  ```
  `display-popup` doesn't expand formats, hence the `run-shell` wrapper (see [pitfalls](pitfalls-and-testing.md#pitfalls-found-while-building)).
- `--popup` makes the popup close by itself on success (the result goes to `display-message`) and pause for Enter only on errors.

### Agent mode

`tmux-connect --from ME <target>` without `--popup` is agent mode, used when the user asks an agent to connect: no picker and no naming form. Permissions allow only this `--from` form.

- A target of `codex` or `claude` means the agent type. It resolves to the single other pane in the caller's window whose `pane_current_command` equals it, or whose name is it or starts with `codex-`/`claude-`.
- Any other target is an exact name (this window first, then anywhere) or a pane id.
- **Names never fall through to tmux.** `resolve_pane` passes a string to tmux as a target only when it looks like one (`is_target`: `%12`, `2`, `2.1`, `work:2`, `work:2.1`). tmux matches other strings loosely, by window name too: a message for a closed agent named `blog.clooney.io-1` was delivered to the agent in a window named `blog.clooney.io`, which happened to be connected, so nothing flagged it. Now an unknown name is an error.
- `codex@WHERE` / `claude@WHERE` looks elsewhere (`where_panes`): a number is a window in the caller's session, `session:window` a window anywhere, anything else a project (the same project `tmux-spawn` uses, exact name first, then by part of it). A project's main agent wins over its sub agents, so "the codex in stone-age" isn't ambiguous just because it has spawned Codex sub agents.
- `--list` prints every pane the caller could connect to, by window, for requests the shorthand can't express ("the codex fixing the login bug"); the agent picks one or asks.
- Several matches or none is an error listing the candidates, so the agent asks the user.
- **Notice across windows.** Connecting to an agent (`claude` or `codex`) in another window sends it a `tmux-ask --notice`: who connected, from which project and window, and how to message back. It didn't see the connection happen, and the first request might come much later. Notices say no reply or action is needed. Sub agents get none: their parent manages them, and a turn ended without replying would mark them as needing the user.
- Unnamed panes are named with `auto_name`.

An earlier version matched names globally first and command substrings for any target, so `codex` could pick a pane of that name in another window and `code` matched `codex-notes`. Codex's review of the change caught both.

## Message protocol

`tmux-ask` pastes text into the target pane and presses Enter, exactly as if the user had typed it. The agent receives it as an ordinary prompt.

```
[request from claude to codex via tmux-ask]
<message>

(You are codex. When done, send your answer back with: tmux-ask --from codex --reply claude <<'MSG'
<your reply>
MSG)
[end of request from claude to codex]
```

```
[reply from codex to claude via tmux-ask]
<message>

(This is a reply. Do not answer it unless you have a new request.)
[end of reply from codex to claude]
```

### Design decisions

- **Push, not call-and-wait.** The sender ends its turn right after sending, and the answer arrives later as a new prompt in its own pane. An earlier design blocked on `tmux wait-for` plus a Stop/notify hook and scraped the reply with `capture-pane`. It was dropped because a peer waiting on a permission prompt would stall the caller, and scraped TUI output is noisy.
- **Loop prevention by convention.** Replies say not to answer, and the `tmux-agents` skill repeats the rule. There is no hop counter.
- **Explicit identity.** Every request names its receiver and puts `--from <receiver>` in the reply command. `self_pane` takes `--from` (a name or pane id) before `$TMUX_PANE`, because `$TMUX_PANE` can be wrong in Codex.
- **Every request carries its own reply instructions**, so an agent that never loaded the skill can still answer.
- **End markers.** Bodies end with `[end of request|reply from X to Y]`. If a user's draft gets submitted along with a message, the skill tells the agent that text outside the markers is the user's, with the user's authority.
- **Trust.** Peer messages look like user input. The skill tells agents that the user's instructions win and to confirm anything destructive with the user.

### Delivery

`tmux-ask` loads the message into a tmux buffer and uses `paste-buffer -p` (bracketed paste), so multi-line text stays one message. It waits `TMUX_ASK_ENTER_DELAY` (default 0.5s), because TUIs can treat an Enter that arrives in the same burst as the paste as a newline, then submits with `send-keys Enter`.

### Not typing over the user

`user_busy` is true when the receiver's pane is in copy mode (where `send-keys Enter` would go to copy mode instead of the program), or a client is showing it and had a keypress in the last `TMUX_ASK_IDLE_SECS` (8s). Then:

1. `tmux-ask` writes the body to `/tmp/tmux-agents-<uid>/queue/<socket>/<epoch>-<pid>-<pane>.msg`. A same-stem `.meta` file records `from_pane`, `from_id`, `from_name`, `to_pane`, `to_id`, `to_name`, `kind` and `queued_at` as `key=value` lines. It is one fixed place per tmux server, so hooks running in the server's environment find it, and per server because pane ids repeat across servers (a test server's `%1` is not the user's `%1`).
2. It starts `tmux-ask --deliver` with `run-shell -b`, so the deliverer lives in the tmux server rather than the sender, and prints `queued`. The skill tells agents that `queued` means sent, so they don't resend.
3. The deliverer polls every 2s, waits for older queued files for the same pane (names sort by time), and delivers once the user is idle. A pane in copy mode with no keypress from a client showing it for `TMUX_ASK_COPY_IDLE_SECS` (default 300, 0 = never) was probably left there by accident: the deliverer cancels copy mode (`send-keys -X cancel`), tells the clients, and delivers. Settings reach the deliverer explicitly on its command line, because `run-shell` runs with the server's environment, not the sender's.
4. While the receiver lives, polling never expires. After `TMUX_ASK_QUEUE_SECS` (30 min), it sets `@msg_waiting_since` so the receiver shows amber `✉ message waiting` in the list and chip. Delivery clears the marker.
5. A receiver that disappears leaves the body as `.undelivered`. The sender gets a notice from `tmux-ask` saying the message did not arrive and giving its path. If the receiver has a session record with an id, the notice says reopening will deliver it. Only when the sender is gone too does this fall back to a toast for every client.

`tmux-ask --pending` lists queued and undelivered files in both legacy flat queues and per-server queues; legacy files without metadata get identities from their protocol header. `--retry [--to NAME]` resolves a live receiver name to its agent ID, then retries matching `to_id` messages oldest first through normal delivery, preserving busy-user queuing. A different agent reusing the label does not receive them. It retries only the current server and legacy flat queue; another server's same-named pane is not a destination. Unavailable receivers keep their files. `tmux-spawn --resume` invokes this after adopting the reopened pane.

Leaving copy mode doesn't wait for the poll: a `pane-mode-changed[42]` hook runs `tmux-ask --kick <pane>`, which sends that pane's queued messages at once, in order, skipping the typing window. tmux counts mouse scrolling as client activity, so waiting it out cost 8 to 10s after every scroll. The hook and deliverer serialize each receiver with a kernel advisory lock (system Perl `Fcntl`). A claimed body becomes `.sending`; successful delivery removes it and its metadata. Process exit releases the lock, including SIGKILL. A later kick, deliverer or retry restores orphaned `.sending` files, and retry also restarts queued messages whose worker did not start. If a process dies after paste but before cleanup, replay may duplicate the message: delivery is at least once, not exactly once.

Detecting drafts in the input line from the screen was prototyped and dropped: it depended on each TUI's look (Codex draws its placeholder dim), and the end markers make it unnecessary.

## Long messages

- **Convention.** The skill asks for a 3 to 5 line summary plus a file path whenever an answer runs past about 20 lines. Claude writes to its session scratchpad; other agents write to `$TMPDIR/tmux-agents/<name>/`.
- **Safety net.** Messages over `TMUX_ASK_MAX_LINES` (default 60) are written to `$TMPDIR/tmux-agents/<sender>/<time>-to-<receiver>.md`. Only the first 15 lines and the path are pasted, which keeps huge pastes out of TUIs.
