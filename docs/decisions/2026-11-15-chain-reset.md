# Clear and re-brief an existing chain

The user approved `chain-reset` to recover an existing chain after clearing the main conversation, preserving pane names, ownership and connections. The user clears the main themselves; the reset workflow only clears descendants.

Every role recovers its trusted preserved name, checks peers and reloads the chain rules. Secondary and worker rejoin without clearing anyone. The worker tells main it is back through a notice to secondary for relay, preserving the existing connection topology.

Main asks secondary for unfinished tasks, commits, CI and worker state before clearing it. A reply is evidence of a stopped turn, but the command still checks current state. Main then clears and re-briefs secondary with the three names and carried work; secondary applies the same ask, clear, re-brief sequence to worker. Nobody interrupts a working agent, and a refusal is inspected and retried later without polling loops.

`tmux-clear-context --from ME PEER` requires explicit caller identity and accepts only a live descendant running Claude, Codex or a configured Codex profile. It refuses working agents, copy mode, typing, queued messages and nonempty prompts. It sends Claude `/clear` or Codex `/new`, clears stale activity and owed state, and resets Codex thread metadata while retaining the pane and its relationships.

`tmux-ask` wraps messages as requests, so sending `/clear` through it does not submit a native slash command. Raw skill-level `send-keys` would bypass ownership, readiness and queue checks. A dedicated guarded command owns that operation; the short skill owns the handoff and re-briefing sequence.

Claude uses the existing cursor-row prompt check, including its idle `❯ Try ...` placeholder. Rejecting that placeholder would block the normal stopped-turn reset. A draft literally starting with `Try ` is an accepted risk, mitigated by the recent-user-input guard; other nonempty input is refused. Codex requires an empty `›` prompt row.
