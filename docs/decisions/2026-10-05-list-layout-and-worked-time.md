# Agent list layout and worked time

**Context.** In the `prefix + a` list, the NAME column is as wide as the longest name, so STATUS and PARENT move whenever a long name appears. Names repeat the project that the group header already shows (`claude-11ty-subspace-builder-secondary` under `▸ 11ty-subspace-builder`). The second row has no width limit, and the list doesn't say how long an agent has been in its state or how long it has worked.

**Decision.**

- **Fixed NAME column.** NAME is 26 cells wide. Within a project group, a name that starts with `<kind>-<project>-` is shown as `<kind>·<rest>` (`claude-11ty-subspace-builder-secondary` → `claude·secondary`). If it's still longer than 26 cells, it's compacted like the chip's `short_task`: keep the start and the end with `…` in the middle. PARENT gets the same treatment when the parent is in the same project. The preview shows the full name.
- **Search matches what's shown.** fzf searches the displayed short name and the project (in the group header and on the second row), with native matching and highlighting and no extra processes. Limitation: a full hyphenated name pasted in order (`claude-tmux-agents-secondary`) won't match, because the display order and the `·` separator differ. Search with its parts instead: space-separated terms match in any order (`claude tmux secondary`).
- **Second row.** The activity (for closed rows, the project) is cut before the STATUS column with `…`, by display width: CJK and other wide characters count 2 cells. The second row's STATUS cell shows the time in the current state and the total worked time: `12m · worked 7m`, `4m · worked 1h5m`, closed `13h · worked 1h20m`. STATUS is as wide as its widest cell.
- **Time format.** Time in state uses one coarse unit: `45s`, `4m`, `2h`, `3d`. Worked time uses up to two units: `7m`, `1h5m`, `2d3h`.
- **Worked time.** A logical turn starts when work begins after done, idle or reopening. Permission, needs-you and message waits pause its clock; returning to working continues the same turn. Done, idle or closure completes it. Checkpoint totals and state time in the session record at every completion or pause, and checkpoint the active interval start when working resumes. Reopening keeps the saved totals and starts a new turn. Agents started before this release count from their first timing event, without backfill.
- **Preview header.** Full name, activity wrapped to preview width in three fixed lines, truncated with `…` or padded when short, started, age, total worked, last turn and number of turns. The seven-line header stays pinned while pane content follows its tail, with a dim full-width separator; closed records show saved activity when available.
- **No new cost.** Everything comes from the existing pane snapshot and record batch: no extra processes, and `list-budget.sh` stays green.
- **Tests.** Column widths and compaction (including CJK), the time formats, and the worked-time accounting.

**Open questions (defaults in bold).**

1. Does waiting on a permission prompt, "needs you" or "message waiting" count as worked time? **No: worked time is time in `working` only. A permission prompt pauses the turn's clock, and it resumes when the state goes back to `working`.**
2. What does a pre-upgrade agent show before its first turn? **No "worked" part (`12m`), rather than `worked 0s`.**
3. Started time for agents spawned before this release? **Unknown. The preview shows `started ?`; new agents get `@started` at spawn.**
4. The time in state needs a new `@state_since`, set wherever `@state` changes (tmux-agent-report, tmux-ask, tmux-spawn, done/idle hooks). **One helper in lib.sh that sets `@state`, `@state_since` and the turn counters together, used by every writer.**
5. Should NAME stay 26 cells in wide popups? **Yes, it's fixed; the extra width goes to the second row's text.**
6. Rows outside their project group (e.g. "needs you" at the top) keep the full kind-project prefix? **Yes. The `kind·rest` short form only applies under a group header that names the project.**

**Why.** Columns that never move are easier to scan, and the project is already in the group header. Time in state and worked time show at a glance which agents are stuck and which are doing the work.

**Rejected.** A NAME column that grows with the longest name (the old behaviour, which moves STATUS and PARENT). Counting worked time from pane age, which counts idle hours as work. Searching the hidden full name, which fzf can't do natively: it would need a filter process per keystroke and would lose match highlighting (decided 2026-10-05).

## Abrupt pane removal (2026-10-05)

Isolated tmux hook checks established these limits:

- `pane-died` with `remain-on-exit` keeps the pane and its options readable. Save the final interval there.
- `pane-exited` supplies `hook_pane`, but with `remain-on-exit` off the pane and its options are already gone.
- `after-kill-pane` runs after removal, has no `hook_pane`, and its format context can be another pane.
- `window-unlinked` supplies `hook_window`; the removed window's panes are already gone.
- There is no hook before a pane is killed, so a removal hook cannot reconstruct the active interval.

Previously, abrupt removal could lose all increments since the last close/save, including completed turns (the entire total for a never-saved new agent). Checkpoints now preserve completed turns and banked work before pauses. At most the current unsaved working interval is lost; an unfinished logical turn is not reported as a completed turn.

Store `pane=` alongside counters. The three after-removal hooks run a batch sweep with one `list-panes` snapshot and no per-record tmux calls, marking records whose pane disappeared `closed=` without adding guessed work. Read candidate bindings before the snapshot and recheck them under each record lock so concurrent resumes with a new pane are not closed by a stale snapshot. This sweep is separate from list building. Legacy records without a pane binding are left alone.

## Preview scrolling

Keep the seven-line header fixed with fzf `~7`, including every `change-preview-window` action. Manual preview wheel, shifted arrows, page keys and half-page keys switch to `nofollow` before scrolling. A focus change resets `follow`. fzf 0.65 documents preview geometry variables and scroll key events, but no bottom-reached event; use explicit `ctrl-f` to return to the tail and resume follow, and show it in the footer and guide. The existing refresh loop starts once on `start`, leaving `focus` available for the native follow reset without launching another loop per agent. No filtering or scroll-monitor process is added.
