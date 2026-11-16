---
name: agent-chain
description: Run a chain of three agents through tmux-agents, a main agent that talks to the user, a secondary that coordinates and merges, and a worker that implements. Use when the user says "start the chain", "agent chain", "end the chain", asks to rejoin after clearing context ("cleared, resume please" or "清完了，继续"), or a message assigns a main, secondary or worker role in an agent chain.
---

# Agent chain

Load the `tmux-agents` skill before using this workflow; follow its identity and messaging rules.

If your brief says you are the secondary or worker, join the existing chain in that role. Never execute "Starting the chain" from a secondary or worker brief.

Three agents work together through tmux-agents: a **main agent** the user talks to, a **secondary** that coordinates, and a **worker** that implements. The user talks to one agent and still sees every agent's work in its own pane.

Names follow `<kind>-<project>-<role>`, e.g. `claude-~-main`, `claude-~-secondary`, `codex-~-worker` at home, or `claude-blog-main` in a project. `tmux-spawn --name <role>` and `tmux-rename` build them from the short role name. Use the names they print, never hard-coded ones.

## Roles

- **Main agent** (the agent the user started). The agent that receives "start the chain" is the main agent. It talks to the user and the other agents: it clarifies intent, reviews plans with the user when present, and relays decisions. It doesn't investigate or implement.
- **Secondary**. Coordinates the worker and owns the main checkout. Small or fully specified tasks go straight to the worker. For open design questions or concerns, it makes the sole exception to its no-spawn role: it spawns a dedicated design agent with `tmux-spawn`. The design agent's default is the smallest plan that solves only confirmed problems; it replies with the plan to the secondary, which sends it to the main for review. After approval, the secondary hands the agreed plan to the worker. It merges the worker's commits, runs the project's steps (importers, backups, server relaunches, tests) and records decisions in docs. Anything that needs a user decision goes to the main agent, not to the user.
- **Worker** (plus its own sub agents). Implements the agreed plan and investigates only its requirements and details. By default it splits independent implementation parts across its own sub agents (`tmux-spawn`), one per part by file ownership, after agreeing the interfaces between them, then integrates and runs the full checks itself. It works alone only on short, strictly sequential or same-file tasks, and says why. Findings go to the secondary; neither the worker nor its agents redesign the plan. If the plan proves unworkable, the worker stops and reports that to the secondary.

## Choosing agents

Each role accepts `claude`, `codex`, a configured Codex profile or an executable basename on PATH. Profiles take precedence over same-named executables. Defaults are `claude` / `claude` / `codex` for main / secondary / worker. See [Configuration](../../docs/configuration.md) for profile mappings and role settings.

Other executables have [limited support](../../docs/agents.md), with no agent-chain skill integration, automatic tracking, worked time, permission setup or resume. Main and secondary are especially risky because their coordination is not guaranteed. An unknown main receives no initial chain prompt; the user must send the actual brief manually with `tmux-ask` once it reaches its prompt. A spawn task for an unknown secondary is not sent either: the main must retain and manually send the role and actual goal after the prompt is ready. For an unknown worker, its owner sends the first task after verifying its prompt. Do not tell these agents to load this skill; use a self-contained task and explicit sender names. Untracked children supply no working-state signal for live waiting.

The agent receiving "start the chain" remains main. The main setting only chooses the new agent launched from a shell; instruction-file preferences cannot change that first launch. If the user explicitly wants another main type, explain that they need a new chain window using the launcher.

Before spawning either member, resolve secondary and worker:

- Use the launcher's initial role/value/source snapshot when present. Otherwise query `tmux-agents chain-config secondary --sources` and `tmux-agents chain-config worker --sources` as separate standalone commands. Do not revalidate the main setting: an existing main is already selected.
- This-chain explicit CLI or user choices win over applicable CLAUDE.md / AGENTS.md role preferences, which win over the snapshot's env / option / default values. Follow your normal instruction hierarchy for file preferences. A file saying the worker uses `codex-2nd` still applies unless this chain explicitly chooses otherwise. The CLI does not read Markdown.
- Validate both final member choices with selected-role queries before spawning, preserving the snapshot and applying any natural-language or instruction-file overrides:
  ```sh
  tmux-agents chain-config secondary --secondary <secondary agent> --sources
  tmux-agents chain-config worker --worker <worker agent> --sources
  ```
  On validation failure, resolve the reported role/profile problem before creating members. Keep profile names as returned; do not replace a profile with `codex`.

The query is read-only and needs no `--from`. Full output is TSV role/value, with `--sources` adding `explicit|env|option|default`. A selected role alone prints its value, for example `tmux-agents chain-config worker`; adding `--sources` prints role/value/source. It shows the settings new chains start from, not the running chain's members; use `tmux-peers` for those. Read the output as data, never `eval` it. Run queries on their own, without command substitution, pipes or shell command chains.

New profiles need the installer run for their existing Codex home so they receive skills and the real rules file. Setting `CODEX_HOME` alone does not install them. The shared launcher carries profile mappings and role environment pins, including for Codex's shared daemon; do not recreate those with skill-level exports. Role settings affect new chains, not existing members or resumed records.

## Starting from a shell

For saved projects, `tmux-agents chain` offers a project picker and `tmux-agents main-sequence` opens configured windows in order. Use `main-sequence list`, `add`, `set` and `unset` to maintain the shared config, including per-window `command` and `resume` fields. Resolve ambiguous matches with a unique window name. See [Project launchers](../../docs/guide.md#project-launchers) for paths, fallback and scan settings.

`tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--main-resume ID] [--secondary AGENT] [--worker AGENT]` opens a new window in DIR (default `$PWD`), names it after DIR's basename (`root` at the filesystem root) unless `--name NAME` is supplied, and launches the selected main.

Without `--target` it opens and focuses the window in the current session. `--target session[:index]` creates it detached in an existing session; a bare session chooses the next free index. Target mode needs no caller pane or `TMUX` variable when tmux can reach the existing server. Flags can appear in any order. All three role choices are validated before window creation. Success prints exactly the new pane ID and a newline to stdout; errors use stderr and a nonzero exit status. Both window rename options (`automatic-rename` and `allow-rename`) are disabled before agent startup. Chain `--name` names the window, unlike the pane label in `start AGENT --name`. For named servers, select the socket through `TMUX` or a `tmux -L NAME` wrapper; there is no launcher socket flag. See [Starting agents](../../docs/guide.md#starting-agents) for examples.

`--main-resume ID` resumes only the main; members start fresh. Claude receives `/rc` before the chain brief, while Codex receives the brief with `resume ID`. Invalid or unavailable IDs and unsupported executables warn and start a fresh main. See [Starting agents](../../docs/guide.md#starting-agents) for session-store checks and startup recovery.

Claude/Codex receive an initial role snapshot and sources; other executables receive no initial prompt. Shell resolution is explicit flag > nonempty environment > nonempty tmux option > default. The main follows the steps below, preserving explicit choices and applying instruction-file member preferences as above. This convenience command is for starting a new chain from a shell, never for secondary or worker role briefs joining an existing chain.

The main keeps its agent's permission defaults. Spawned Claude/Codex members default to auto mode unless `@tmux_agents_sub_auto off` or `TMUX_AGENTS_SUB_AUTO=off` selects agent defaults.

## Starting the chain (main agent)

`<me>` is your current name (`tmux-peers` shows it). The skill-loading briefs below are for Claude/Codex. For other executables, follow the manual task delivery rules above: no supplied spawn brief is sent to the new agent, and an unknown recipient must not be told to load this skill.

The spawn commands below use `--message-file` to keep each role brief in a file. The file must be one readable regular file, not a symlink, and at most 1 MiB; its literal text is sent. Empty content follows normal no-task behavior. This option conflicts with positional task text; stdin is ignored. It cannot be combined with `--resume` or `--list-closed`. Create each message file with `mktemp` under `${TMPDIR:-/tmp}/tmux-agents/$ME/` so agents sharing a working directory cannot overwrite one another or dirty the project; remove it after successful delivery or keep it for a retry.

1. `tmux-rename --from <me> <me> main` renames you to `<kind>-<project>-main`. Use the new name as `<me>` from then on.
2. Spawn the resolved secondary to your right; use its printed full name as `<secondary>`:

   ```sh
   message_dir="${TMPDIR:-/tmp}/tmux-agents/$ME"
   mkdir -p "$message_dir"
   secondary_brief="$(mktemp "$message_dir/secondary.XXXXXX")"
   # write the brief to "$secondary_brief"; remove after successful delivery
   tmux-spawn <secondary agent> --from <me> --member --split <me> --right --name secondary --message-file "$secondary_brief"
   ```

3. Spawn the worker for the secondary, below it:

   ```sh
   worker_brief="$(mktemp "$message_dir/worker.XXXXXX")"
   # write the brief to "$worker_brief"; remove after successful delivery
   tmux-spawn <worker agent> --from <me> --member --for <secondary> --split <secondary> --below --name worker --message-file "$worker_brief"
   ```

   The worker becomes the secondary's long-lived member, connected to the secondary only (not to you), and starts without a task. The secondary gets the brief, introduces itself to the worker (including that it is the worker in the agent chain and splits independent parts across sub agents by default) and sends the first task.
4. Tell the user the three printed names and end your turn. The layout, all in your window: you on the left half, the secondary top right, the worker bottom right.

Spawn both from the top-level main agent (no `@parent` and no `@member`); only top-level callers can spawn members. The restriction checks the caller, not the `--for` owner, so the main can give the secondary a worker member. `--for` makes the worker the secondary's member, but depth always counts from the caller plus one. Both chain members are depth 1; the worker's ordinary helpers are depth 2, the normal default limit. Helpers do not inherit membership. The main agent doesn't message the worker; it goes through the secondary (`tmux-ask --any` only if the user asks). Each Claude/Codex brief names the agent's role in the agent chain, so it loads this skill; beyond that, it only needs the other agents' names and the current goal.

The secondary and worker are long-lived members: they stay out of the default sub-agent list, ordinary chip counts and `--done` cleanup. Find them with `ctrl-a` in the agent list, labelled `member of <owner>`; attention still pins them in the list and chip.

## Rejoining after a restart or clear

Treat "cleared, resume please" or "清完了，继续" after a context clear as a request to restore the existing chain's roles and review its handoff. The user need not repeat the role or procedure. Follow the tmux-agents identity rules, then use `tmux-peers --from <me>` and the recorded role suffix to identify yourself and current members. If identity or role is unclear, ask only for the missing information. Keep existing names and connections; do not spawn a replacement chain or reopen an old conversation to restore roles.

Main re-briefs the secondary on its role and current member names, asking it to restore the worker's role in turn. Secondary and worker rejoin their roles and wait for assigned work; they do not automatically restart old tasks. Report surviving background work, worktrees and uncommitted changes so a fresh context does not duplicate or discard them.

Main reads the project-root `HANDOFF.md` saved through the wrap-up skill. Present a short numbered list of important outcomes, unfinished choices and live work the user needs to know about. Continue work explicitly selected by the user before the clear; otherwise wait for their selection, such as "do 2 and 3", or a new task. A role-restoration request alone is not permission to resume every old task. If no handoff exists, say so and ask for the current goal rather than inventing lost context.

Main also refreshes its existing project-launcher resume field. Run `tmux-agents main-sequence list`, match the project directory and window name to one agent row, then use `tmux-agents main-sequence set NAME resume=ID` and verify with `list`. Use the new conversation ID from the session record keyed by main's verified stable agent ID, not that agent ID itself or an old ID copied from the handoff. Claude records it at prompt start; Codex records it only at the new thread's first turn end. For Codex, ask secondary to perform the update after main completes this post-clear turn and the fresh thread binding is confirmed; keep the update pending until then. If no coordinator is available, keep it for main's next turn. Do not claim it is updated before verification. Missing or ambiguous rows require clarification; leave shell and command rows unchanged and do not add a new row automatically.

`HANDOFF.md` is temporary and must never be committed. Before creating or updating it, check that it is untracked and locally excluded from Git; preserve unrelated contents. Remove an entry only once completed, explicitly dropped or transferred to a user-approved durable record. Delete the file when all its entries are handled, not merely after reading it. Use wrap-up again before another clear to refresh the remaining handoff.

Manual clearing with Claude `/clear` or Codex `/new` is supported: tracking and `tmux-spawn --resume` follow the new conversation when its hooks report it. Restoring roles does not itself clear any agent's context.

## Ending the chain

`tmux-dismiss --from <me> <secondary>` closes the secondary, the worker and the worker's sub agents. Claude/Codex members with resumable conversations can be reopened with `tmux-spawn --resume <name> --from <me>`, preserving membership, or in place from a returned shell with `tmux-spawn --resume-id <id> --here`. Existing chains keep their sub-agent status until restarted; there is no conversion command.

## Fleet Command (when installed)

Check `command -v fleet-command`; if absent, keep the existing chain behavior unchanged with no hard dependency.
When present, follow the `missions` skill and use your own recorded tmux-agents name: pass `--from NAME` before every subcommand or set `FLEET_AGENT`.

- **Main:** create a mission with `fleet-command mission add "TITLE"`, retain its printed ID and send direction with `fleet-command send SECONDARY "TEXT" --mission ID`; pass the mission ID onward with delegated work.
- **Secondary:** start each turn with `fleet-command inbox`; update status and owner with `fleet-command mission set ID --status STATUS --owner NAME` and record decisions with `fleet-command log MISSION_ID "TEXT" --kind decision`.
- **Fleet instructions:** answer with `fleet-command reply ID "ANSWER"` so they leave the inbox; do not use `tmux-ask` for these replies. Keep ordinary tmux messages on the existing message workflow.
- **Worker:** only append progress, handoff or completion with `fleet-command log MISSION_ID "TEXT" --kind KIND`, choosing `progress`, `handoff` or `done`; the secondary owns status changes.

## Messages

- For an open design question, the design agent replies with its plan to the secondary, which sends it to the main for review. When the user is present, the main briefly walks them through it and relays their approval; when the user is away, the chain decides and records the decision in the away log. Only after approval does the secondary send the agreed plan to the worker. If implementation shows the plan does not work, the worker stops and reports to the secondary, which decides whether to return to design.

In Codex code mode, `exec_command` remains a shell tool. Prefer quoted arguments or `--message-file` to heredocs for the briefs above. Run one tmux command per tool call, with file preparation and cleanup in separate calls; if socket permission denial persists, retry only the failed command with narrow escalation as described in the tmux-agents skill.

- Main and secondary: `waiting on <member>` is computed live from the nearest working descendants. An idle or done member has stopped its turn; inspect its last report or use `tmux-peek`. A watchdog finding an idle member with a finished result should pick it up. Ended turns accrue no worked time, including while waiting on CI. Use plain progress reports for direct Codex work and follow the tmux-agents skill before asking the user a question.
- Follow the [tmux-agents message rules](../tmux-agents/SKILL.md#receiving-a-message) for sending, replying and reading attached messages.
- **Relay the original.** When a message needs little or no change, preserve its message kind and send only a short summary with what you add plus the original's `Read the full message here: tmux-read <id>` line. This includes the secondary relaying worker results to the main.
- The user reads the secondary's messages to the main agent directly, so the main agent doesn't restate them; it brings up a decision as a one-line summary plus options.
- Send progress, handoff updates, partial completions ("X landed") and plan updates with `tmux-ask --note`. A decision uses a request stating the default and what is blocked meanwhile. Awaited results and matters needing the user (release completion, CI failure, push approval and decisions) remain ordinary replies, requests or notices, never notes.
- Main reads `tmux-notes --from ME` when the user asks or at a natural pause and shares the useful points, without repeating every note. Codex also checks notes at each turn start alongside the missions inbox rule.
- Reply as soon as a request's main work is done (e.g. the release is out). Don't hold the reply for follow-ups such as a deploy going live; send those later as notices. For a request with several parts, send a note as each part lands; send the awaited result as an ordinary reply.
- When the secondary sends the worker a task on a branch or worktree behind main, it adds a line like `main is N commits ahead: <subjects>` from `git log --oneline HEAD..origin/main | head -5`.
- If a reply is slow, inspect the receiver with `tmux-peek`.
- An instruction the user gives directly to any agent wins; that agent tells the others what changed.

## Working across projects

Whenever work crosses project boundaries:

- Each project's secondary is its interface to other projects. Cross-project requests go secondary to secondary, never straight to another project's main agent or worker. If that project has no chain, talk to its main or current agent.
- Requests are self-contained (goal, paths, constraints, deliverable); the receiving project decides how and who does it.
- Agents only edit their own project's files. Changes elsewhere are requested from that project's agents.
- User decisions go back up the requesting chain to its main agent, the one the user is talking to. Ask the other project's main agent only about decisions purely about its own project.
- The main agent reaches other projects through its secondary; `tmux-ask --any` only when the user asks.
