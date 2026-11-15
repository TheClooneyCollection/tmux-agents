---
name: chain-reset
description: Recover and re-brief an existing agent chain after clearing context. Use when the user says /chain-reset, chain reset, or re-brief the chain.
---

# Chain reset

Load [tmux-agents](../tmux-agents/SKILL.md) and [agent-chain](../agent-chain/SKILL.md). Recover your preserved pane-border name using tmux-agents' trusted identity rules, then run `tmux-peers --from NAME`. If identity is unknown, ask the user for the pane-border name. The `-main`, `-secondary` or `-worker` suffix identifies your role; an ambiguous name or missing peer needs clarification before proceeding. Keep existing panes, names and connections.

## Secondary or worker

Rejoin your existing role; clear nobody. Secondary sends main a `tmux-ask --from NAME --notice MAIN` notice that it is back. Worker sends that notice to secondary and explicitly asks it to relay the return to main. Follow the carried-work brief when it arrives; do not start another chain.

## Main

1. Ask the connected secondary with `tmux-ask --from MAIN SECONDARY` to report unfinished tasks, commits, CI and worker state, including the worker's full name. End your turn for its reply; never interrupt it.
2. Retain the reply as the handoff and stopped-turn evidence. Run `tmux-clear-context --from MAIN SECONDARY`. The command still refuses a currently working agent, copy mode, typing, queued messages or a nonempty prompt. If refused, inspect with `tmux-peek --from MAIN SECONDARY` and retry later when ready, without a polling loop or force-clear.
3. After success, use `tmux-ask --from MAIN SECONDARY` to re-brief its secondary role, main and worker names, and all carried work. Tell it to load agent-chain and tmux-agents, then apply this same ask, clear, re-brief sequence to its worker: collect the worker's handoff, clear with `tmux-clear-context --from SECONDARY WORKER`, and restore the worker role, chain names and carried work. Ask secondary to report completion or any refusal.
4. After secondary reports the worker re-briefed, tell the user the three preserved names and carried work. If a step is blocked, report that instead of claiming the reset completed.

The user clears main themselves. Use the guarded command for descendants; `tmux-ask` carries the brief, not the native `/clear` or `/new` command.
