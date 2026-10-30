# Codex turn-start observability

Status: **Proposal**. No behaviour change is approved or implemented here.

## Problem and evidence

Task state answers whether an agent owes work; it does not reliably answer
whether Codex is executing a model turn. For example, a finished helper can
receive a reply or informational notice, process it and report progress while
still displaying `done`. An idle receiver likewise has no automatic Codex
start signal; an ordinary report can start it, unlike a report on `done`.

The isolated CLI reproduction on v1.17.1 and main `0f255f2` demonstrated that
notices, unsolicited replies and ordinary progress reports leave a done agent
done. A separate read-only live diagnosis on 2026-10-30 observed completion
notifications on a done agent and a later rollout `task_started` event. Those
sequential observations support an observability gap, not a precise atomic
measurement of execution. The reproduction used stub agents and simulated
notifications; it did not prove real Codex lifecycle emission. Private project
names, thread IDs and transcripts are intentionally omitted.

Source anchors at proposal base `912c53b`:

- [Launcher integration](../../bin/lib.sh), `build_agent_command`, installs
  Codex completion `notify` with a stable agent ID, without a turn-start hook.
- [Report handling](../../bin/tmux-agent-report), the `--codex-notify` branch
  and final progress path, handles completion and preserves done summaries.
- [Request state](../../bin/tmux-request-state), `notify` and `finish`, keeps
  obligations separate and refuses to invent an unreported start interval.
- [Done state and cleanup](sub-agents.md#done-state-and-cleanup) explains
  request reopening, notice semantics and reports after completion.

A closed historical record intercepting a resumed thread's notification is a
separate routing defect. Fixing routing cannot supply the missing start event.
Likewise, old activity text or zero banked seconds alone does not prove that
Codex is idle or that completion notifications are absent.

## Preserve message meaning

Converting notices into requests would create an incoming obligation and an
outgoing wait, require a reply, and potentially produce `needs_you` when the
receiver merely acknowledges information. A notice means no answer or work is
required. Replies settle existing obligations. Neither should acquire a new
obligation just to animate a status indicator. Ordinary progress after a reply
must also remain usable as a final summary.

## Candidates and tradeoffs

1. **Observe rollout lifecycle events.** Explore `task_started` with matching
   completion/interruption events for supported Codex versions. This could
   expose turns triggered by user text, replies or notices without changing
   their semantics. It requires a version/schema compatibility policy; rollout
   JSONL is not established here as a stable integration contract. File discovery
   must respect the launched profile's home. Tailing must handle partial lines,
   buffering, rotation, truncation, resume, duplicate events and watcher restarts.
   Bind events to the live stable agent identity and launch generation as well
   as thread/turn identity: a historical thread or recycled pane is insufficient.
   Event timestamps, receipt delays and clock changes need explicit treatment;
   an unmatched start or missing end must become unknown/stale, not permanent
   execution. Define interruption and process-exit handling before shipping.
   A watcher adds lifecycle cleanup, file I/O, parsing and support cost. Keep it
   outside list builds and measure resource use and start-to-display latency;
   never rescan every rollout for each agent or retain prompt contents.
2. **Show model execution separately from task state.** A small executing,
   stopped or unknown indicator could coexist with `done`, `working` or
   `needs_you`. This preserves request accounting, child waits and cleanup
   semantics. It still needs a trustworthy signal such as candidate 1; a second
   icon alone does not solve detection. It adds UI complexity and needs a clear
   explanation that task waiting is not model execution. Do not silently reuse
   task worked-time or completed-task counters as model-turn metrics.
3. **Keep explicit reporting only.** This has no watcher or schema dependency,
   but relies on agents reporting new local work and cannot show every turn.
   Making all progress reports reopen done would break final-summary behaviour.

Candidates 1 and 2 can be combined. Before implementation, decide supported
versions, signal ownership, stale/unknown presentation, and whether execution
needs its own timing at all. Validate reply/notice/direct-input turns, late
callbacks after resume, interrupted turns and watcher failures on isolated
servers, while retaining request semantics and the list-build budget.

## Available explicit workaround

For known local work that continues beyond one turn, the agent can report:

```sh
tmux-agent-report --from my-agent --local "reviewing follow-up evidence"
# When that local work is complete:
tmux-agent-report --from my-agent --local-done
```

Use the actual agent name. These commands explicitly start and finish the local
obligation while preserving independent requests and waits. They are not needed
to turn a purely informational notice into work. They do not detect model turns,
reconstruct historical elapsed time, or repair past counters. Completion notify
alone cannot recover when an unobserved turn began. See
[local work and turn ends](sub-agents.md#data-not-screen-scraping) for the current integration.
