# Agent list layout and worked time

**Context.** In the `prefix + a` list, the NAME column is as wide as the longest name, so STATUS and PARENT move whenever a long name appears. Names repeat the project that the group header already shows (`claude-11ty-subspace-builder-secondary` under `▸ 11ty-subspace-builder`). The second row has no width limit, and the list doesn't say how long an agent has been in its state or how long it has worked.

**Decision.**

- **Fixed NAME column.** NAME is 26 cells wide. Within a project group, a name that starts with `<kind>-<project>-` is shown as `<kind>·<rest>` (`claude-11ty-subspace-builder-secondary` → `claude·secondary`). If it's still longer than 26 cells, it's compacted like the chip's `short_task`: keep the start and the end with `…` in the middle. PARENT gets the same treatment when the parent is in the same project. The preview shows the full name.
- **Search matches what's shown.** fzf searches the displayed short name and the project (in the group header and on the second row), with native matching and highlighting and no extra processes. Limitation: a full hyphenated name pasted in order (`claude-tmux-agents-secondary`) won't match, because the display order and the `·` separator differ. Search with its parts instead: space-separated terms match in any order (`claude tmux secondary`).
- **Second row.** The activity (for closed rows, the project) is cut before the STATUS column with `…`, by display width: CJK and other wide characters count 2 cells. The second row's STATUS cell shows the time in the current state and the total worked time: `12m · worked 7m`, `4m · worked 1h5m`, closed `13h · worked 1h20m`. STATUS is as wide as its widest cell.
- **Time format.** Time in state uses one coarse unit: `45s`, `4m`, `2h`, `3d`. Worked time uses up to two units: `7m`, `1h5m`, `2d3h`.
- **Worked time.** A turn starts when the state becomes `working` and ends when it leaves `working`. The turn's length is added to a running total, and the last turn's length and the turn count are kept. They're pane options while the agent is live, and are written into its session record when it closes. `--resume` reads them back and keeps adding. Agents started before this release count from the upgrade.
- **Preview header.** Full name, started, age, total worked, last turn and number of turns.
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
