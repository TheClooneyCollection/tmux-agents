---
name: agent-chain
description: Run mission-based agent teams through tmux-agents. Use for "start the chain", "end the chain", or an assigned chain role.
---

# Agent chain

Load `tmux-agents` for identity, messaging and lifecycle rules. A role brief joins the existing mission; only the agent receiving "start the chain" becomes main. `secondary` remains an alias for `interface`, including existing agent names.

## Roles

Read `tmux-agents status` for the configured agents, model args and sources.

| Role | Spawned by | Lifetime |
| --- | --- | --- |
| main | user | long-lived |
| designer | main | per design |
| interface (secondary) | main after plan approval | per mission |
| worker | interface | per task |
| reviewer | interface before landing, or main on request | per review |
| runner | main or interface | per task |
| researcher | whoever needs facts | per task |

- **Main talks and decides; it does not do.** Its long-lived context is the most expensive, so keep it for the user: talk, read mission state, write briefs, send messages and make quick lookups of one or two tool calls. Delegate anything needing more than two calls or any waiting to the cheapest capable role: commands/watches to runner, research to researcher, landing to the mission interface, design to designer. If a delegate cannot solve a problem, decide or ask the user; never fix it yourself.
- **Designer** discusses directly with the user in its pane and writes the smallest plan solving confirmed problems, split by file ownership with fixed interfaces.
- **Interface** dispatches the plan, one worker per part, and lands its own mission through CI and `done` (below). Send plan gaps to main; main only grants landing turns, one interface at a time.
- **Worker** implements one part in its own worktree and runs its tests, with no sub agents. Stop and report an unworkable plan to interface.
- **Reviewer** reviews before landing. Use Fable for review or design only when the user asks, overriding reviewer or designer with `-- --model fable`.
- **Runner** handles ad hoc commands and CI watching; prefer scripts for repeatable runs.
- **Researcher** reads code and returns a short summary to whoever requested the facts.

Spawn by role; use the printed full name and check its resolution line. Trusted panes omit `--from`; unpinned Codex supplies its verified name. Pass briefs directly using the [message forms](../tmux-agents/SKILL.md#long-messages).

```sh
tmux-spawn --role designer --mission M5 --open 'Discuss M5 with the user and write the plan.'
tmux-spawn --role interface --member --mission M5 'Dispatch the approved M5 plan; spawn helpers with --role.'
tmux-spawn --role worker --name parser-tests 'Implement the assigned parser tests.'
tmux-spawn --role reviewer 'Review the mission branch against the approved plan.'
tmux-spawn --role runner 'Run tmux-agents ci --watch and reply with the result.'
tmux-spawn --role researcher 'Check the specified behavior and return evidence.'
```

`--mission` transfers ownership, so reserve it for the mission owner. `--name` replaces the role's default name. `-- ARGS` replaces role args; a bare `--` clears them. Explicit AGENT overrides are for user-requested changes and warn when role args are dropped. Only the user or main changes live defaults with `tmux-agents chain-config set ROLE AGENT [-- ARGS]`; Codex prompts for approval. Args are space-separated words without shell quoting. The command prints persistent tmux.conf lines. A running chain retains the all-role snapshot taken at launch; inspect that snapshot with `status`. Apply instruction-file preferences at launch through role flags or settings, not by silently replacing the configured profile at each spawn. See [role settings](../../docs/configuration.md#chain-roles). Other executables need [manual brief delivery](../../docs/agents.md#sending-the-first-task).

Interface is main's `--member` at depth 1. Its workers, reviewer and runner are ordinary sub agents at depth 2 and cannot spawn further. A depth-2 agent needing research asks its interface to dispatch it. Only main is long-lived. Hidden windows are the default; use `--split` only when the user asks for a layout.

## Starting the chain (main agent)

1. Run `tmux-agents status`; keep your name. The chain launcher records `@role main`. Only a depth-0 agent with no claimed role runs `tmux-agents role main --from ME` when status shows the claim hint, including when told it is the main of an existing chain.
2. Create missions with the CLI below. Start independent missions immediately, with no cap; anything that does not depend on a pending design or result starts now.
3. For each mission, follow the flow below. Existing role briefs never start another chain.

## Missions

Mission state is `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/missions/<project>/M<N>.mission` (key=value), with optional `M<N>.log`. Only the owner writes its mission; main may set any mission. Use `tmux-agents mission add TITLE`, `show ID`, `list` or `tmux-agents board --watch`. Changes go through the CLI:

- `tmux-agents mission set ID --status S [--notify PEER] [--notice]` changes state and optionally sends a quiet note, or an interrupting notice. `--owner NAME` transfers ownership separately when needed.
- `tmux-agents mission done ID "report path or summary" [--notify NAME]` marks done, logs completion and optionally notifies. Send the awaited reply separately before dismissal.
- `tmux-ask --note PEER --mission ID "progress"` and `tmux-agent-report --mission ID "progress"` also append local progress logs. Use `mission log ID TEXT --kind K` for other log kinds.

Statuses: `design`, `plan-ready`, `active`, `needs-decision`, `ready-to-push`, `done`. Log kinds: `progress`, `decision`, `handoff`, `done`. Every message carries its mission tag, e.g. `[M3 token-waste]`; briefs include goal, constraints and known paths.

1. **Design.** Main adds a mission, spawns `--role designer --mission ID --open` with status `design`. The user discusses the design there; designer logs decisions in the decision doc, writes the plan, uses `mission set ID --status plan-ready --notify MAIN --notice`, with the plan path recorded in the mission log.
2. **Dispatch.** After user approval, main spawns `--role interface --member --mission ID` with the approved plan path. Interface marks it `active` and dispatches every independent part immediately with `--role worker`, one worker and worktree per part. Briefs fix file ownership and interfaces. For a branch behind main, include `main is N commits ahead: <subjects>` from `git log --oneline HEAD..origin/main | head -5`.
3. **Review.** Each mission has its own branch/worktree. Interface runs the reviewer and required checks, using scripts or runner; workers fix findings within the plan. Interface integrates parts one at a time by rebase and `git merge --ff-only`, then sets `ready-to-push`. Plan gaps become `needs-decision` requests to main.
4. **Land and complete.** After user push approval, main grants one interface the landing turn. That interface rebases its mission onto main, lands with `git merge --ff-only`, pushes, watches CI itself or through runner, runs `mission done ID "handoff/report path" --notify MAIN` and replies with the result. Main dismisses its subtree and designer only after this reply. Keep agents while changes are unclean or unlanded, CI is running, or push approval is pending.

A small follow-up joins its open mission. Agents update mission state and send notes; main reads the board when the user asks. Only plan-ready, a decision request, completion, CI failure or push approval interrupts main. Batch user decisions across missions into one numbered list.

## Messages and checks

Follow the [message rules](../tmux-agents/SKILL.md#receiving-a-message): notes by default in both directions, replies for awaited results, requests for decisions (state the default and what is blocked). Main does not restate interface messages the user already sees.

Pass long briefs and reports directly: Claude uses quoted heredoc stdin; Codex one quoted multi-line argument. Add `--summary` for large reports so the receiver gets a summary and retained `tmux-read` pointer. Copy the exact reply command from the generated request footer. Codex uses `tmux-ask --reply -- "answer"`; Claude uses `tmux-ask --reply NAME` with quoted heredoc stdin. Nameless replies are safe only with a single open request; otherwise name the requester. Forward the original pointer and message kind, not the body. Keep each tmux command standalone.

Codex checks `tmux-agents status --notes` at turn start. Main reads notes on request or at a natural pause. `waiting on` reflects working descendants; idle/done means the turn ended. Inspect the last report or `tmux-peek` before chasing a slow result. Direct user instructions win; tell the affected agents what changed.

Resume after a context clear is handled by the wrap-up skill, maintained separately.

## Ending the chain

`tmux-dismiss --from ME INTERFACE` closes one mission's interface subtree; dismiss its designer separately. End all missions to end the chain, respecting the completion guards above. Reopening and membership preservation follow the tmux-agents skill; old `secondary` names remain valid.

## Working across projects

Requests go interface to interface, or to the other project's current agent if it has no chain. Include goal, paths, constraints and deliverable; that project decides who implements and edits its own files. User decisions return through the requesting chain's main. Use `tmux-ask --any` only when the user asks.
