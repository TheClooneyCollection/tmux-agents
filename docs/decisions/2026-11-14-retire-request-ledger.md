# Retire the request ledger for turn state

Status: proposed on 2026-11-14, awaiting the user's approval. Nothing is implemented until then.

## Context

[Request completion](2026-10-24-request-completion-and-overdue.md) gave every request an ID and derived an agent's state from a durable ledger: pending incoming requests, outgoing requests to live receivers, live children, `--waiting` text, `--local` work and Claude background commands. In daily use that state is often wrong, and wrong in ways that make people and agents act on it:

- **Stale "waiting for X".** Panes show `working · waiting for X` long after X went idle, because an outgoing request stays pending until X replies with the right ID, however the work actually ended.
- **Working while idle.** A worker ended its turn to wait for CI, with `--waiting "rebased profile full suite and dual-platform CI"`. It sat idle at its prompt from 11:58 while the list showed it working. CI went green at about 12:11, and nobody noticed until main's watchdog flagged the stalled release.
- **Stuck `needs you`.** The blog worker finished its task and stayed `◆ needs you`, because a request was still pending in the ledger.
- **Batched requests.** When several requests arrive in one turn and the agent answers them in one reply, only the named request resolves. The rest stay pending, so the agent shows `needs you` or keeps its requester waiting. This was queued as a post-v1.19.0 fix.
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

- Claude: the existing hooks drive it, with `UserPromptSubmit` as turn start and `Stop` / `StopFailure` as turn end. The permission, tool, question and elicitation hooks are unchanged.
- Codex has no turn-start hook. Delivering a `tmux-ask` paste or a `tmux-spawn` task marks it `working`, and the Codex notify callback ends the turn. Explicit `--needs-you` keeps its current lifetime and clears on the next turn start.
- An agent that ends its turn is `idle` or `done`, full stop. Background waits (CI watches, Claude background commands, "I'll wait for X") are not modelled.

### "Waiting for whom" is computed live

- When the list and chip are built, an agent whose sub agents or members are currently `working` shows that it is waiting on them, for example `idle · waiting on codex-worker`.
- The input is the same single pane snapshot the list already takes. Nothing is stored, so nothing can go stale.
- The agent's own state is not changed by this. It is idle or done, and its children are working.

### Unanswered-stop notice: one slot per agent

The notice from v1.19.0 stays, without the ledger. Each sub agent keeps one slot: the last request it received, its sender, and whether it has messaged that sender since.

- A new request overwrites the slot.
- Any message to that sender clears it: a reply, a notice or a request.
- If the sub agent's turn ends while the slot is still owed, the sender gets the notice once, for example `worker stopped without replying to your last request`. It doesn't fire again for the same slot.
- Scope stays as today: sub agents only, live agent senders only.

### Removed

- The request ledger: `bin/tmux-request-state`, per-request IDs, pending and resolved records, publication journals, owed-reply bookkeeping, and the `incoming`, `resolve`, `finish` and `restore` operations.
- The rule that an unanswered request at turn end means `needs you`.
- Ledger-derived `working · waiting for X`.
- `tmux-ask --request-id`, `tmux-agent-report --waiting`, `--local` and `--local-done`. See Compatibility.
- Claude background-command detection (`claude_background`) as a reason to stay working.
- The queued post-v1.19.0 batched-requests fix. It has nothing left to fix.

### Kept

- `tmux-ask --reply` as a message kind. It only changes the header (`[reply from ...]`) and the guidance text, with no bookkeeping.
- `--notice`, `--any`, `--message-file`, `tmux-read`, long-message handling, queued delivery, retry, bounce and deliver-on-reopen.
- Plain `tmux-agent-report "<text>"` progress and `--needs-you`.
- `@attention_since` for the `needs you` age. It is now set and cleared by the state transition itself instead of by the ledger.

### Compatibility for old callers

Live agents carry old instructions in their context ("reply with `--request-id r…`"), and old reply commands sit in scrollback and notes. Breaking them at upgrade time would make agents fail to reply at all, so the old forms are accepted for a deprecation window:

| Old form | Behaviour during the window |
| --- | --- |
| `tmux-ask --request-id ID --reply NAME` | Accepted. The ID is ignored and the reply is sent to NAME. A one-line stderr note says `--request-id` is no longer needed. |
| `--request-id` without `--reply` | Same note, then sent as an ordinary request. It no longer errors. |
| `tmux-agent-report --waiting "text"` and `--local "text"` | Treated as a plain progress report of `text`. No state change, plus a stderr note. |
| `tmux-agent-report --local-done` | A no-op that exits 0, with a stderr note. |

The window lasts at least until the release after the one that ships this change. Removing the flags after it is a breaking change, so it needs its own user decision.

Request messages no longer print a `--request-id` in their reply guidance. A summary sent with `--message-file` gets a fresh `m…` ID, since there's no request ID to reuse. `tmux-read` keeps accepting existing `r…` IDs until those files expire.

## Migration on install

On every tmux server, run once, triggered by `install.sh` for the current server and lazily by the first tmux-agents command on any other server. It is guarded by a server-level `@tmux_agents_state_version` option:

1. **Unset ledger pane options:** `@awaiting`, `@waiting_on`, `@request_local_work`, `@request_local_done` and `@request_notify_digest`.
2. **Recompute ledger-derived states.**
   - A tracked pane showing `working` with no turn in progress (`@turn_active` unset) goes to `idle` (top level) or `done` (sub agent). Its activity text is cleared if it starts with `waiting for`.
   - A pane showing `needs you` keeps it only if it has a permission wait, an open question or dialog, or explicit needs-you. Otherwise it goes to `idle` or `done`.
3. **Delete the ledger directory** `${XDG_STATE_HOME}/tmux-agents/<socket>/requests/`: records, contexts, journals and the lock. Its `stop_notified` sets are not carried over, since the new slot starts empty.
4. **Accept old queued messages.** Their `request_id=` field is ignored and they are delivered normally.

## Skill text changes

- **tmux-agents skill.**
  - Remove the `--request-id` reply instructions, `--waiting`, `--local` / `--local-done`, the "ending your turn while waiting" rules, and the advice to acknowledge with a notice because a reply closes the request.
  - Replies become `tmux-ask --reply NAME`, sent once the work is done.
  - Interim updates may use any kind, but `--notice` stays the convention for FYIs.
  - Describe the states as above, including that an agent which ends its turn shows idle or done even if it plans to come back.
- **agent-chain skill.**
  - Drop the request-ID wording in the reply templates.
  - Tell the main and the secondary that `waiting on <member>` is live. A member that is idle has stopped, so check its last report or `tmux-peek` instead of trusting an old "working".
  - Watchdog guidance: an idle member with a finished result is the signal to pick it up.
- **Request footers.** The pasted footer (`(You are X. When done, reply with: ...)`) drops `--request-id`.

## Docs

Update DESIGN.md, `docs/design/state-and-protocol.md` and `docs/design/sub-agents.md`, the guide, and `docs/configuration.md`, which currently tells a Codex main to use `--local` / `--local-done`. Also update both READMEs where they mention request IDs, and the CHANGELOG.

## Test impact

- **Removed or rewritten from scratch:** `tests/request-lifecycle.sh`, `request-publication.sh`, `request-resilience.sh`, `request-completion.sh` and `request-hooks.sh`, which become a turn-state hook suite. `request-reply-mode.sh` becomes reply-kind formatting only.
- **Rewritten:** `tests/needs-you.sh`, which covers only the hook and explicit sources.
- **Edited to drop IDs and removed flags:** about a dozen suites, including `ask-message-file`, `agent-ids`, `launcher`, `list-scope`, `names`, `members`, `read`, `rename`, `retry-isolation`, `resumed-thread`, `resume-here`, `resume-messages`, `start-takeover`, `tracking` and `sub-exit`.
- **New behaviour tests:**
  - Turn-state transitions for Claude and Codex.
  - Live `waiting on` from working children, which disappears the moment they stop.
  - The one-slot notice: overwrite, clear on any message, fires once.
  - The deprecated flags behave as listed above.
  - Migration of pane options, states and the ledger directory.
  - `tmux-read` of an old `r…` ID.

The list's single-snapshot and record-read budget must hold, and the list gets cheaper without the ledger read.

## Known limits

- **Codex direct typing.** When the user types into a Codex pane directly, the state updates only at turn end, so a running Codex turn the user started shows `idle`. Codex has no turn-start or permission hook, so a Codex approval prompt also shows `working`.
- **Background waits are invisible.** An agent waiting on CI or a background command shows idle or done until something starts its next turn. This is intended: idle with an unfinished task is exactly the case a coordinator should look at.
- **Only the latest request is remembered.** If a sub agent receives requests from two senders and answers only the later one, the earlier sender gets no stop notice.
- **Live waiting covers sub agents and members only.** Requests to unrelated or cross-project agents don't show as waiting.

## Why

- Turn hooks are the only signal that is always true at the moment it is read. Everything the ledger added was a stored belief about the future, such as a reply that will come or a wait that will end, and those beliefs went stale in each failure above.
- Computing relationships from the live snapshot removes a whole class of stale-state bugs and their cleanup code, and makes the list cheaper.
- The one remaining useful signal from the ledger, "a sub agent stopped owing someone an answer", needs only one slot per agent.

## Rejected alternatives

- **Fix the ledger:** resolve all pending requests from a sender on any reply, expire stale waits, and so on. Each fix patches one symptom of stored state drifting from reality. The batched-request, stale-wait and stale-ID bugs are separate instances of the same design problem, and more rules would make agents' reply etiquette heavier, not lighter.
- **Keep `--waiting`:** it is the source of the "working while idle" failure. A declared wait has no reliable end signal, because the agent forgets to clear it or the wait finishes while the agent is not running, so the display lies in exactly the case where a human needs the truth.
- **Remove `--request-id` with an immediate error:** live agents would fail to reply in the middle of the upgrade.
- **Stored "waiting for" with expiry:** it is still stale until it expires, and it needs a timeout setting. The live computation needs neither.
