---
name: agent-chain
description: Run mission-based agent teams through tmux-agents. Use for "start the chain", "end the chain", rejoining after a clear ("cleared, resume please" or "清完了，继续"), or an assigned chain role.
---

# Agent chain

Load `tmux-agents` for identity, messaging and lifecycle rules. A role brief joins the existing mission; only the agent receiving "start the chain" becomes main. `secondary` remains an alias for `interface`, including existing agent names.

## Roles

| Role | Default agent / model | Spawned by | Lifetime |
| --- | --- | --- | --- |
| main | claude / Opus 5.5 | user | long-lived |
| designer | claude / Opus 5.5 | main | per design |
| interface (secondary) | claude / Sonnet | main after plan approval | per mission |
| worker | codex | interface | per task |
| reviewer | claude / Opus 5.5 | interface before landing, or main on request | per review |
| runner | scripts first; claude / Haiku | main or interface | per task |
| researcher | claude / Sonnet | whoever needs facts | per task |

- **Main talks and decides; it does not do.** Its long-lived context is the most expensive, so keep it for the user: talk, read mission state, write briefs, send messages and make quick lookups of one or two tool calls. Delegate anything needing more than two calls or any waiting to the cheapest capable role: commands/watches to runner (Haiku), research to researcher (Sonnet), landing to the mission interface, design to designer. If a delegate cannot solve a problem, decide or ask the user; never fix it yourself.
- **Designer** discusses directly with the user in its pane and writes the smallest plan solving confirmed problems, split by file ownership with fixed interfaces.
- **Interface** dispatches the plan, one worker per part, and lands its own mission through CI and `done` (below). Send plan gaps to main; main only grants landing turns, one interface at a time.
- **Worker** implements one part in its own worktree and runs its tests, with no sub agents. Stop and report an unworkable plan to interface.
- **Reviewer** reviews before landing. Use Fable for review or design only when the user asks, overriding reviewer or designer with `-- --model fable`.
- **Runner** handles ad hoc commands and CI watching; prefer scripts for repeatable runs.
- **Researcher** reads code and returns a short summary to whoever requested the facts.

Spawn by consumer with `tmux-spawn --role ROLE --from ME --message-file PATH`; use the printed full name. Role settings supply the agent and model: inspect `tmux-agents chain-config --args --sources` as data, never `eval`. `--name` overrides the role name; a positional AGENT precedes `--role` (e.g. `tmux-spawn codex --role reviewer`) and overrides the role agent, and `-- ARGS` replaces role args (bare `--` clears them).

This-chain explicit choices win over applicable instruction-file role preferences, then launcher snapshot/settings. Keep configured profile names. For interface/worker overrides, validate with `tmux-agents chain-config ROLE --interface AGENT` or `--worker AGENT`; do not revalidate an already-running main. See [role settings](../../docs/configuration.md#chain-roles) and [shell launchers](../../docs/guide.md#starting-agents) for configuration and `start chain`. Other executables need [manual brief delivery](../../docs/agents.md#sending-the-first-task), with no skill integration or automatic tracking.

Interface is main's `--member` at depth 1. Its workers, reviewer and runner are ordinary sub agents at depth 2 and cannot spawn further. A depth-2 agent needing research asks its interface to dispatch it. Only main is long-lived. Hidden windows are the default; use `--split` only when the user asks for a layout.

## Starting the chain (main agent)

1. Rename yourself with `tmux-rename --from ME ME main`, then use the printed name.
2. Create missions with the CLI below. Start independent missions immediately, with no cap; anything that does not depend on a pending design or result starts now.
3. For each mission, follow the flow below. Existing role briefs never start another chain.

## Missions

Mission state is `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/missions/<project>/M<N>.mission` (key=value), with optional `M<N>.log`. Only the current owner writes its mission; main may set any mission. Write only through `tmux-agents mission add --from ME TITLE`, `set --from ME ID --status S --owner O`, or `log --from ME ID TEXT --kind K`; read with `tmux-agents mission show --from ME ID`, `list --from ME`, or `tmux-agents board --watch`.

Statuses: `design`, `plan-ready`, `active`, `needs-decision`, `ready-to-push`, `done`. Log kinds: `progress`, `decision`, `handoff`, `done`. Every message carries its mission tag, e.g. `[M3 token-waste]`; briefs include goal, constraints and known paths.

1. **Design.** Main adds a mission, spawns `--role designer` and sets it as owner with status `design`. Open its pane for the user with `tmux-agents open NAME --from ME`. The user discusses the design there; designer logs decisions in the decision doc, writes the plan, sets the mission to `plan-ready` and sends main one notice with the path.
2. **Dispatch.** After user approval, main spawns `--role interface --member` with the approved plan path and sets interface as mission owner. Interface marks it `active` and dispatches every independent part immediately with `--role worker`, one worker and worktree per part. Briefs fix file ownership and interfaces. For a branch behind main, include `main is N commits ahead: <subjects>` from `git log --oneline HEAD..origin/main | head -5`.
3. **Review.** Each mission has its own branch/worktree. Interface runs the reviewer and required checks, using scripts or runner; workers fix findings within the plan. Interface integrates parts one at a time by rebase and `git merge --ff-only`, then sets `ready-to-push`. Plan gaps become `needs-decision` requests to main.
4. **Land and complete.** After user push approval, main grants one interface the landing turn. That interface rebases its mission onto main, lands with `git merge --ff-only`, pushes, watches CI itself or through runner, sets the mission `done` and replies with a handoff/report path. Main dismisses its subtree and designer only after this reply. Keep agents while changes are unclean or unlanded, CI is running, or push approval is pending.

A small follow-up joins its open mission. Agents update mission state and send notes; main reads the board when the user asks. Only plan-ready, a decision request, completion, CI failure or push approval interrupts main. Batch user decisions across missions into one numbered list.

## Messages and checks

Follow the [message rules](../tmux-agents/SKILL.md#receiving-a-message): notes by default in both directions, replies for awaited results, requests for decisions (state the default and what is blocked). Main does not restate interface messages the user already sees.

Reports over about ten lines go in a unique `mktemp` file under `${TMPDIR:-/tmp}/tmux-agents/$ME/`, sent with `--message-file PATH` and a summary of at most five lines. Forward the original `tmux-read` pointer and message kind, not the body. Briefs also use unique files there. Read only what is needed; batch independent read-only checks, keeping each tmux command standalone.

Codex checks `tmux-notes --from ME` at turn start. Main reads notes on request or at a natural pause. `waiting on` reflects working descendants; idle/done means the turn ended. Inspect the last report or `tmux-peek` before chasing a slow result. Direct user instructions win; tell the affected agents what changed.

## Rejoining after a restart or clear

Treat "cleared, resume please" or "清完了，继续" after a context clear as a request to restore the existing chain's roles and review its handoff. The user need not repeat the role or procedure. Follow the tmux-agents identity rules, then use `tmux-peers --from <me>` and the recorded role suffix to identify yourself and current members. If identity or role is unclear, ask only for the missing information. Keep existing names and connections; do not spawn a replacement chain or reopen an old conversation to restore roles.

Recognise old `secondary` names as interfaces. Main re-briefs each mission interface on its role, mission ID, plan path and current member names, asking it to restore its workers' roles in turn. Interface and worker rejoin their roles and wait for assigned work; they do not automatically restart old tasks. Report surviving background work, worktrees and uncommitted changes so a fresh context does not duplicate or discard them.

Main reads the mission board, then the project-root `HANDOFF.md` saved through the wrap-up skill. Present a short numbered list of important outcomes, unfinished choices and live work the user needs to know about. Continue work explicitly selected by the user before the clear; otherwise wait for their selection, such as "do 2 and 3", or a new task. A role-restoration request alone is not permission to resume every old task. If no handoff exists, say so and ask for the current goal rather than inventing lost context.

Main delegates its existing project-launcher resume-field refresh to interface or runner. Run `tmux-agents main-sequence list`, match the project directory and window name to one agent row, then use `tmux-agents main-sequence set NAME resume=ID` and verify with `list`. Use the new conversation ID from the session record keyed by main's verified stable agent ID, not that agent ID itself or an old ID copied from the handoff. Claude records it at prompt start; Codex records it only at the new thread's first turn end. For Codex, wait until main finishes its post-clear turn and the fresh thread binding is confirmed; keep the delegated update pending until then. Do not claim it is updated before verification. Missing or ambiguous rows require clarification; leave shell and command rows unchanged and do not add a new row automatically.

`HANDOFF.md` is temporary and must never be committed. Before creating or updating it, check that it is untracked and locally excluded from Git; preserve unrelated contents. Remove an entry only once completed, explicitly dropped or transferred to a user-approved durable record. Delete the file when all its entries are handled, not merely after reading it. Use wrap-up again before another clear to refresh the remaining handoff.

Manual clearing with Claude `/clear` or Codex `/new` is supported: tracking and `tmux-spawn --resume` follow the new conversation when its hooks report it. Restoring roles does not itself clear any agent's context.

## Ending the chain

`tmux-dismiss --from ME INTERFACE` closes one mission's interface subtree; dismiss its designer separately. End all missions to end the chain, respecting the completion guards above. Reopening and membership preservation follow the tmux-agents skill; old `secondary` names remain valid.

## Fleet Command (when installed)

Check `command -v fleet-command`. When available, mirror missions using the `missions` skill; interface takes its secondary duties. Keep local mission records authoritative. Use your own recorded name with `--from NAME` before subcommands. Interface checks `inbox` at turn start, owns status updates and answers Fleet instructions with `fleet-command reply`, not `tmux-ask`. Workers only log progress, handoff or done. An unavailable server does not block the task.

## Working across projects

Requests go interface to interface, or to the other project's current agent if it has no chain. Include goal, paths, constraints and deliverable; that project decides who implements and edits its own files. User decisions return through the requesting chain's main. Use `tmux-ask --any` only when the user asks.
