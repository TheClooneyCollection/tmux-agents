# Clear and re-brief an existing chain

## Superseded (2026-11-15)

The user retired automated context clearing and the separate recovery skill. Clearing stays manual: when an existing chain member is restarted or cleared, recover its current role and peers and re-brief the current goal through main, secondary and worker. This keeps recovery in the agent-chain workflow without automating native conversation resets.

## Original decision

The user approved `chain-reset` to recover an existing chain after clearing the main conversation, preserving pane names, ownership and connections. The user clears the main themselves; the reset workflow only clears descendants.

Every role recovers its trusted preserved name, checks peers and reloads the chain rules. Secondary and worker rejoin without clearing anyone. The worker tells main it is back through a notice to secondary for relay, preserving the existing connection topology.

Main asks secondary for unfinished tasks, commits, CI and worker state before clearing it. A reply is evidence of a stopped turn, but the command still checks current state. Main then clears and re-briefs secondary with the three names and carried work; secondary applies the same ask, clear, re-brief sequence to worker. Nobody interrupts a working agent, and a refusal is inspected and retried later without polling loops.

`tmux-clear-context --from ME PEER` requires explicit caller identity and accepts only a live descendant running Claude, Codex or a configured Codex profile. It refuses working agents, copy mode, typing, queued messages and nonempty prompts. It sends Claude `/clear` or Codex `/new`, clears stale activity, and resets Codex thread metadata while retaining the pane and its relationships.

`tmux-ask` wraps messages as requests, so sending `/clear` through it does not submit a native slash command. Raw skill-level `send-keys` would bypass ownership, readiness and queue checks. A dedicated guarded command owns that operation; the short skill owns the handoff and re-briefing sequence.

Claude and Codex use the same cursor-row check with their respective prompt glyphs. ANSI dim history suggestions and placeholders are empty input only while the cursor remains just after the glyph and its space. The parser handles the no-break space explicitly, independently of locale. Non-dim drafts, including text starting with `Try `, and cursors past the input start are refused.

If readiness changes after typing the native command, remove it with one Backspace per character only when the same pane identity remains outside copy mode and its non-dim input and cursor still exactly match that command. Otherwise send no further keys and report that the input was left as is. Working refusals include the age of the recorded state so stale activity is visible.
