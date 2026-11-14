# Retire the request ledger for turn state

Status: proposed on 2026-11-14 and revised after review the same day. It awaits the user's approval, and nothing is implemented until then.

## Context

[Request completion](2026-10-24-request-completion-and-overdue.md) gave every request an ID and derived an agent's state from a durable ledger. The ledger combined pending incoming requests, outgoing requests to live receivers, live children, `--waiting` text, `--local` work and Claude background commands. In daily use that state is often wrong, and wrong in ways that make people and agents act on it:

- **Stale "waiting for X".** Panes show `working · waiting for X` long after X went idle. An outgoing request stays pending until X replies with the right ID, however the work actually ended.
- **Working while idle.** A worker ended its turn to wait for CI, with `--waiting "rebased profile full suite and dual-platform CI"`. It sat idle at its prompt from 11:58 while the list showed it working. CI went green at about 12:11, and nobody noticed until main's watchdog flagged the stalled release.
- **Stuck `needs you`.** The blog worker finished its task and stayed `◆ needs you`, because a request was still pending in the ledger.
- **Batched requests.** Several requests arrive in one turn and the agent answers them in one reply. Only the named request resolves, and the rest stay pending, so the agent shows `needs you` or keeps its requester waiting. This was queued as a post-v1.19.0 fix.
- **Reply-ID friction.** An interim acknowledgement sent with `--reply --request-id` closes the request, so the real answer then fails with `request does not match this pending reply`. After a restart the same error hits a stale ID. Agents resend as notices and keep notes on how to avoid it.

Every one of these is the ledger's stored belief drifting from what the agents are actually doing. Orca-style tools show state straight from the agent's turn and compute relationships when they are displayed, so there is nothing to drift.

## Decision

The user decided on 2026-11-14:

### State comes only from turns

| Event | State |
| --- | --- |
| A turn is running | `working` |
| A turn ends | `idle` for a top-level agent, `done` for a sub agent |
| A permission prompt, `AskUserQuestion`, an MCP input dialog, or `tmux-agent-report --needs-you` | `needs you` |

What counts as a turn start, per agent:

- **Claude.**
  - `UserPromptSubmit` (`--turn-start`) starts a turn, and `Stop` / `StopFailure` (`--turn-end`) ends it.
  - Claude can also be re-invoked without a prompt submit, for example when a background command or an Agent-tool result returns. So `PreToolUse` (`--tool-start`, already wired) on a tracked `idle` or `done` pane also sets `working`.
  - The permission, tool, question and elicitation hooks are otherwise unchanged.
- **Codex.**
  - Codex has no turn-start hook. Any delivered paste of any kind marks the receiver `working`: request, reply, notice, system notice (rename, bounce), `--any` send, a retried message or one delivered on reopen. It happens at actual delivery, not at send time.
  - The notify callback ends the turn. A notify whose `input-messages` do not contain the most recently delivered paste's header does not end current work. That paste was delivered after this turn began and has started, or will start, a turn of its own.
- **Progress reports.** A plain `tmux-agent-report "<text>"` still moves `idle` or `done` to `working`. A report can only be sent from inside a running turn, so it is turn evidence, and it covers a Codex agent working on a task typed directly by the user.
- **Explicit needs you.** `--needs-you` lasts until the next turn start. For Codex that means the next delivered paste or progress report.
- **Notice-only turns.** A turn triggered only by a notice shows `working` while it runs. An existing `needs you`, explicit or from a hook, survives it, and only a non-notice turn start or a progress report clears it.
- **Background waits are not modelled.** An agent that ends its turn is `idle` or `done`, full stop. This covers CI watches, Claude background commands and "I'll wait for X".

### "Waiting on whom" is computed live

- When the list and chip are built, an agent shows the working agents it is waiting on. These are its nearest working descendants: walk down its sub agents and members, stopping at each working agent.
  - A main whose secondary is `done` but whose worker is working shows `waiting on <worker>`.
  - Agents that show `needs you` are not listed. They already surface themselves.
- **Rendering.** It is appended to the activity text, for example `idle · waiting on codex-worker` for a top-level agent and `done · waiting on …` for a sub agent. The chip's focus text shows the same suffix.
- **Counting.** The chip counts by each agent's own `@state`, so a parent waiting on a worker counts as idle or done, not working.
- The input is the same single pane snapshot the list already takes. Nothing is stored, so nothing can go stale.

### Unanswered-stop notice: one slot per agent

The notice from v1.19.0 stays, without the ledger. Each sub agent keeps one slot: the agent that most recently asked it something, when that was delivered, and whether the sender has been notified.

- **Storage.** The slot lives in pane options: `@owed_to` (agent ID), `@owed_at` (delivery time) and `@owed_notified`. It doesn't survive a closed pane. On reopen, deliver-on-reopen re-delivers queued messages, and those fill it again.
- **Filling.** The slot is filled at delivery, not at send time, by a request from an agent, or by a reply from the agent the slot is already owed to. The second case covers a sub agent that asks its requester a clarifying question, which clears the slot: the answer re-arms the original obligation. Notices and system notices never fill the slot, and neither do messages from shell panes.
- **Clearing.** Any message from the sub agent to `@owed_to` clears the slot: a reply, a notice or a request.
- **Re-arming.** A new turn start clears `@owed_notified`, so a stall after a nudge is reported again.
- **Settling.** At turn end, the slot is settled only if it was filled before the turn that is ending began:
  - Claude: `@owed_at` is earlier than the turn's start, which is recorded by `--turn-start` or `--tool-start` as described above.
  - Codex: the notify's `input-messages` contain the slot's request header. `bin/tmux-agent-report` already extracts it.
  - A slot filled mid-turn waits for the turn that handles it.
- **Firing.** If a settled slot is still owed and not yet notified, the sender gets one notice, for example `worker stopped without replying to your last request`.
- **Scope.** The receiver must be a sub agent, and the sender must be a live agent pane, not a shell pane.

### Removed

- The request ledger: `bin/tmux-request-state`, per-request IDs, pending and resolved records, publication journals, owed-reply bookkeeping, and the `incoming`, `resolve`, `finish`, `restore` and `sync` operations.
- The rule that an unanswered request at turn end means `needs you`.
- Ledger-derived `working · waiting for X`, and the `@awaiting` and `@waiting_on` reads in `refresh_labels`.
- `tmux-ask --request-id`, `tmux-agent-report --waiting`, `--local` and `--local-done`. See Compatibility.
- Claude background-command detection (`claude_background`) as a reason to stay working.
- The queued post-v1.19.0 batched-requests fix. It has nothing left to fix.

### Kept

- `tmux-ask --reply` as a message kind. It only changes the header (`[reply from ...]`) and the guidance text, with no bookkeeping.
- `--notice`, `--any`, `--message-file`, `tmux-read`, long-message handling, queued delivery, retry, bounce and deliver-on-reopen.
- Plain progress reports and `--needs-you`.
- `@attention_since` for the `needs you` age. It is now set and cleared by the state transition itself instead of by the ledger.
- Resume. `agent_restore_work` restores to `done` as today. Pending messages delivered on reopen then mark the agent `working` like any other delivery, which replaces the ledger's `restore`.

### Worked time

- Worked time now counts only running turns.
- A parent that ends its turn to wait for a member stops accruing worked time and is counted as a finished turn. Before, its `waiting for X` kept it working, so the waiting time counted as worked and one turn spanned the whole task.
- `turns` now counts actual turns.
- The list-layout docs are updated to match.

### Compatibility for old callers

Live agents carry old instructions in their context ("reply with `--request-id r…`"), and old reply commands sit in scrollback and notes. Breaking them at upgrade time would make agents fail to reply at all, so the old forms are accepted for a deprecation window:

| Old form | Behaviour during the window |
| --- | --- |
| `tmux-ask --request-id ID --reply NAME` | Accepted. The ID is ignored and the reply is sent to NAME. A one-line stderr note says `--request-id` is no longer needed. |
| `--request-id` without `--reply` | Same note, then sent as an ordinary request. It no longer errors. |
| `tmux-agent-report --waiting "text"` and `--local "text"` | Treated as a plain progress report of `text`, with a stderr note. |
| `tmux-agent-report --local-done` | A no-op that exits 0, with a stderr note. |

The window lasts at least until the release after the one that ships this change. Removing the flags after it is a breaking change, so it needs its own user decision.

Request messages no longer print a `--request-id` in their reply guidance. A summary sent with `--message-file` gets a fresh `m…` ID, which `tmux-read` already accepts. Existing `r…` message files stay readable until they expire. Old queued messages still parse: their `request_id=` meta field is read and ignored.

## Migration on install

The migration runs once per tmux server and is guarded by a server-level `@tmux_agents_state_version` option.

- **Triggers.**
  - `install.sh` runs it for the server in `$TMUX` when it is run inside tmux. Outside tmux it targets the default socket if a server is running, and otherwise skips.
  - On any other server it runs lazily from the commands that already write state: `tmux-ask`, `tmux-spawn`, `tmux-agent-report` and `tmux-agents start`.
  - The check never runs on the list or chip paths, which keeps the [list build budget](2026-10-04-list-build-budget.md).

Steps:

1. **Recompute ledger-derived states.** Run this first, while the old options are still readable.
   - A tracked `working` pane whose `@activity` starts with `waiting for ` goes to `idle` (top level) or `done` (sub agent) through `agent_set_state`, so its worked time and turn counters close normally. Its activity text is cleared.
   - Other `working` panes are left alone. Their next `Stop`, notify or delivery settles them.
   - A pane showing `needs you` keeps it only if it has a permission wait (`@perm_since`), an open question or dialog (`@asking`), or explicit needs-you. Otherwise it goes to `idle` or `done` the same way.
2. **Unset ledger pane options:** `@awaiting`, `@waiting_on`, `@request_local_work`, `@request_local_done` and `@request_notify_digest`.
3. **Delete the ledger directory** `${XDG_STATE_HOME}/tmux-agents/<socket>/requests/`: records, contexts, journals and the lock. Its `stop_notified` sets are not carried over, since every slot starts empty.

## Skill text changes

- **tmux-agents skill.**
  - Remove the `--request-id` reply instructions, `--waiting`, `--local` / `--local-done`, the rules for ending a turn while waiting, and the advice to acknowledge with a notice because a reply closes the request.
  - Replies become `tmux-ask --reply NAME`, sent once the work is done. `--notice` stays the convention for FYIs.
  - Describe the states as above, including that an agent which ends its turn shows idle or done even if it plans to come back.
  - Tell Codex agents to run `tmux-agent-report --needs-you "<question>"` before asking the user anything in their own pane, since a Codex turn end no longer infers it.
- **agent-chain skill.**
  - Drop the request-ID wording in the reply templates.
  - Tell the main and the secondary that `waiting on <member>` is live. A member that is idle or done has stopped, so check its last report or `tmux-peek` instead of trusting an old "working".
  - Watchdog guidance: an idle member with a finished result is the signal to pick it up.
- **Request footers.** The pasted footer (`(You are X. When done, reply with: ...)`) drops `--request-id`.

## Docs

Update these:

- DESIGN.md, `docs/design/state-and-protocol.md` (including the notice-turn rule) and `docs/design/sub-agents.md`
- the guide, and the list-layout description of worked time
- `docs/configuration.md`, which tells a Codex main to use `--local` / `--local-done`
- both READMEs where they mention request IDs
- the CHANGELOG

## Test impact

- **Removed or rewritten from scratch:** `tests/request-lifecycle.sh`, `request-publication.sh`, `request-resilience.sh`, `request-completion.sh` and `request-hooks.sh`, which becomes a turn-state hook suite. `request-reply-mode.sh` becomes reply-kind formatting only.
- **Rewritten:** `tests/needs-you.sh`, which covers only the hook and explicit sources.
- **Edited to drop IDs and removed flags:** about fifteen suites, including `ask-message-file`, `agent-ids`, `launcher`, `list-scope`, `names`, `members`, `read`, `rename`, `retry-isolation`, `resumed-thread`, `resume-here`, `resume-messages`, `start-takeover`, `tracking` and `sub-exit`.
- **New behaviour tests:**
  - Claude turn start from `UserPromptSubmit` and from `PreToolUse` after a `Stop`.
  - Codex working on every delivered kind, including retry and reopen.
  - A Codex notify that lacks the latest paste does not end work.
  - A progress report moves idle to working.
  - Live `waiting on`: nearest working descendants, gone the moment they stop, not counted as working by the chip.
  - The one-slot notice: fill at delivery, mid-turn delivery not settled early, a reply from the owed agent re-arms, re-arm at turn start, cleared by any message, notices and shells excluded.
  - The deprecated flags behave as listed above.
  - Migration of `waiting for` panes, ledger `needs you`, the options and the directory, on both trigger paths.
  - `tmux-read` of an old `r…` ID, and an old queued meta with `request_id=`.

The list's single-snapshot and record-read budget must hold, and the list gets cheaper without the ledger read.

## Known limits

- **Codex direct typing.** When the user types into a Codex pane directly, the state updates only at turn end or on a progress report, so such a turn can show `idle`.
- **Codex asking the user.** A Codex agent that asks the user in its own pane shows `idle` or `done` unless it reports `--needs-you` first. This applies to sub agents and top-level agents. A sub agent's requester still gets the stop notice.
- **Codex approval prompts.** Codex has no permission hook, so an approval prompt shows `working`.
- **Background waits are invisible.** An agent waiting on CI or a background command shows idle or done until something starts its next turn. That is intended, because idle with an unfinished task is exactly the case a coordinator should look at. Two consequences:
  - A Claude sub agent waiting on its own background command is `done`, so `tmux-dismiss --done` can close it before the command returns.
  - Claude turns that start without a prompt are caught only once they make a tool call.
- **Only the latest request is remembered.** If a sub agent receives requests from two senders and answers only the later one, the earlier sender gets no stop notice.
- **Live waiting covers sub agents and members only.** Requests to unrelated or cross-project agents don't show as waiting.

## Why

- Turn hooks are the only signal that is always true at the moment it is read. Everything the ledger added was a stored belief about the future, such as a reply that will come or a wait that will end, and those beliefs went stale in each failure above.
- Computing relationships from the live snapshot removes a whole class of stale-state bugs and their cleanup code, and makes the list cheaper.
- The one remaining useful signal from the ledger, "a sub agent stopped owing someone an answer", needs only one slot per agent. It also has to respect turn boundaries, so a message delivered mid-turn is not mistaken for one the agent ignored.

## Rejected alternatives

- **Fix the ledger:** resolve all pending requests from a sender on any reply, expire stale waits, and so on. Each fix patches one symptom of stored state drifting from reality. The batched-request, stale-wait and stale-ID bugs are separate instances of the same design problem, and more rules would make agents' reply etiquette heavier, not lighter.
- **Keep `--waiting`:** it is the source of the "working while idle" failure. A declared wait has no reliable end signal, because the agent forgets to clear it or the wait finishes while the agent is not running, so the display lies in exactly the case where a human needs the truth.
- **Remove `--request-id` with an immediate error:** live agents would fail to reply in the middle of the upgrade.
- **Stored "waiting for" with expiry:** it is still stale until it expires, and it needs a timeout setting. The live computation needs neither.
- **Migrating on `@turn_active`:** it is set for every working pane, including the stale ones, so it cannot tell them apart.

## Review decisions

The user decided these on 2026-11-14, after the review:

1. **Codex asking the user.** A Codex agent asking the user does not surface as `needs you` on its own. The skill requires `tmux-agent-report --needs-you` before asking.
2. **Notice-only turns.** A turn triggered only by a notice shows `working` while it runs, but an existing `needs you` (explicit or from a hook) survives it. Only a non-notice turn start or a progress report clears `needs you`.
3. **Worked time.** Worked time excludes waits, and `turns` counts real turns, as described under Worked time.
