---
name: agent-chain
description: Run a chain of three agents through tmux-agents, a main agent that talks to the user, a secondary that coordinates and merges, and a worker that implements. Use when the user says "start the chain", "agent chain", "end the chain" or similar, and whenever a message says you are the main agent, secondary or worker in the agent chain.
---

# Agent chain

Load the `tmux-agents` skill before using this workflow; follow its identity and messaging rules.

If your brief says you are the secondary or worker, join the existing chain in that role. Never execute "Starting the chain" from a secondary or worker brief.

Three agents work together through tmux-agents: a **main agent** the user talks to, a **secondary** that coordinates, and a **worker** that implements. The user talks to one agent and still sees every agent's work in its own pane.

Names follow `<kind>-<project>-<role>`, e.g. `claude-~-main`, `claude-~-secondary`, `codex-~-worker` at home, or `claude-blog-main` in a project. `tmux-spawn --name <role>` and `tmux-rename` build them from the short role name. Use the names they print, never hard-coded ones.

## Roles

- **Main agent** (the agent the user started). The agent that receives "start the chain" is the main agent. It talks to the user and the other agents: it clarifies intent, turns it into self-contained tasks and relays the user's decisions. It doesn't investigate or implement.
- **Secondary**. Coordinates the worker and owns the main checkout. It merges the worker's commits, runs the project's steps (importers, backups, server relaunches, tests) and records decisions in docs. Anything that needs a user decision goes to the main agent, not to the user.
- **Worker** (plus its own sub agents). The main implementer. By default it splits a task with independent parts across its own sub agents (`tmux-spawn`), one per part by file ownership, after agreeing the interfaces between them, then integrates and runs the full checks itself. It works alone only on short, strictly sequential or same-file tasks, and says why.

## Choosing agents

Each role accepts `claude`, `codex`, a configured Codex profile or an executable basename on PATH. Profiles take precedence over same-named executables. Defaults are `claude` / `claude` / `codex` for main / secondary / worker. See [Configuration](../../docs/configuration.md) for profile mappings and role settings.

Other executables have [limited support](../../docs/agents.md), with no agent-chain skill integration, automatic tracking, worked time, permission setup or resume. Main and secondary are especially risky because their coordination is not guaranteed. An unknown main receives no initial chain prompt; the user must send the actual brief manually with `tmux-ask` once it reaches its prompt. A spawn task for an unknown secondary is not sent either: the main must retain and manually send the role and actual goal after the prompt is ready. For an unknown worker, its owner sends the first task after verifying its prompt. Do not tell these agents to load this skill; use a self-contained task and explicit sender names. Existing waiting logic can leave a tracked parent working indefinitely while an untracked child remains live.

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

`tmux-agents start chain [DIR] [--target session[:index]] [--name NAME] [--main AGENT] [--secondary AGENT] [--worker AGENT]` opens a new window in DIR (default `$PWD`), names it after DIR's basename (`root` at the filesystem root) unless `--name NAME` is supplied, and launches the selected main.

Without `--target` it opens and focuses the window in the current session. `--target session[:index]` creates it detached in an existing session; a bare session chooses the next free index. Target mode needs no caller pane or `TMUX` variable when tmux can reach the existing server. Flags can appear in any order. All three role choices are validated before window creation. Success prints exactly the new pane ID and a newline to stdout; errors use stderr and a nonzero exit status. Both window rename options (`automatic-rename` and `allow-rename`) are disabled before agent startup. Chain `--name` names the window, unlike the pane label in `start AGENT --name`. For named servers, select the socket through `TMUX` or a `tmux -L NAME` wrapper; there is no launcher socket flag. See [Starting agents](../../docs/guide.md#starting-agents) for examples.

Claude/Codex receive an initial role snapshot and sources; other executables receive no initial prompt. Shell resolution is explicit flag > nonempty environment > nonempty tmux option > default. The main follows the steps below, preserving explicit choices and applying instruction-file member preferences as above. This convenience command is for starting a new chain from a shell, never for secondary or worker role briefs joining an existing chain.

The main keeps its agent's permission defaults. Spawned Claude/Codex members default to auto mode unless `@tmux_agents_sub_auto off` or `TMUX_AGENTS_SUB_AUTO=off` selects agent defaults.

## Starting the chain (main agent)

`<me>` is your current name (`tmux-peers` shows it). The skill-loading briefs below are for Claude/Codex. For other executables, follow the manual task delivery rules above: no supplied spawn brief is sent to the new agent, and an unknown recipient must not be told to load this skill.

1. `tmux-rename --from <me> <me> main` renames you to `<kind>-<project>-main`. Use the new name as `<me>` from then on.
2. Spawn the resolved secondary to your right; use its printed full name as `<secondary>`:

   ```sh
   tmux-spawn <secondary agent> --from <me> --member --split <me> --right --name secondary <<'MSG'
   You are the secondary in the agent chain (agent-chain skill). Main: <me>.
   Current goal: <goal>
   MSG
   ```

3. Spawn the worker for the secondary, below it:

   ```sh
   tmux-spawn <worker agent> --from <me> --member --for <secondary> --split <secondary> --below --name worker <<'MSG'
   <Brief for the secondary: the worker's role and its first goal.>
   MSG
   ```

   The worker becomes the secondary's long-lived member, connected to the secondary only (not to you), and starts without a task. The secondary gets the brief, introduces itself to the worker (including that it is the worker in the agent chain and splits independent parts across sub agents by default) and sends the first task.
4. Tell the user the three printed names and end your turn. The layout, all in your window: you on the left half, the secondary top right, the worker bottom right.

Spawn both from the top-level main agent (no `@parent` and no `@member`); only top-level callers can spawn members. The restriction checks the caller, not the `--for` owner, so the main can give the secondary a worker member. `--for` makes the worker the secondary's member, but depth always counts from the caller plus one. Both chain members are depth 1; the worker's ordinary helpers are depth 2, the normal default limit. Helpers do not inherit membership. The main agent doesn't message the worker; it goes through the secondary (`tmux-ask --any` only if the user asks). Each Claude/Codex brief names the agent's role in the agent chain, so it loads this skill; beyond that, it only needs the other agents' names and the current goal.

The secondary and worker are long-lived members: they stay out of the default sub-agent list, ordinary chip counts and `--done` cleanup. Find them with `ctrl-a` in the agent list, labelled `member of <owner>`; attention still pins them in the list and chip.

## Ending the chain

`tmux-dismiss --from <me> <secondary>` closes the secondary, the worker and the worker's sub agents. Claude/Codex members with resumable conversations can be reopened with `tmux-spawn --resume <name> --from <me>`, preserving membership. Existing chains keep their sub-agent status until restarted; there is no conversion command.

## Messages

- At the beginning of each new direct user request, including repeated identical tasks, the main runs `tmux-agent-report --from <me> --local "<what you are doing>"`; when that local task is complete, it runs `tmux-agent-report --from <me> --local-done` without trailing text. Other requests and waits remain active. Follow the tmux-agents skill's `--local` rule to reset notification deduplication when identical input cannot identify a new turn. Codex has no turn-start hook, so its turn-end notify cannot protect work before that notification. Use ordinary progress reports inside peer requests and explicit `--waiting` for background waits, following the tmux-agents skill.
- Everything goes through `tmux-ask`. Answer each request with its supplied `--request-id`, following the tmux-agents skill's rules for older ambiguous replies. A reply completes that request, including from a nonparent; other requests and work remain active. Long reports go in a file; the message is a short summary plus the path.
- The user reads the secondary's messages to the main agent directly, so the main agent doesn't restate them; it brings up a decision as a one-line summary plus options.
- Send FYIs as notices (`tmux-ask --notice`), not requests: a request makes the receiver work again and the sender wait for a reply, even if it says "no reply needed". A decision request states the default and what is blocked meanwhile.
- Reply as soon as a request's main work is done (e.g. the release is out). Don't hold the reply for follow-ups such as a deploy going live; send those later as notices. For a request with several parts, send a notice as each part lands.
- `reply overdue` means a delivered request lacks observable progress for the configured interval. Inspect the receiver with `tmux-peek`; it does not itself mean `needs you`.
- An instruction the user gives directly to any agent wins; that agent tells the others what changed.

## Working across projects

Whenever work crosses project boundaries:

- Each project's secondary is its interface to other projects. Cross-project requests go secondary to secondary, never straight to another project's main agent or worker. If that project has no chain, talk to its main or current agent.
- Requests are self-contained (goal, paths, constraints, deliverable); the receiving project decides how and who does it.
- Agents only edit their own project's files. Changes elsewhere are requested from that project's agents.
- User decisions go back up the requesting chain to its main agent, the one the user is talking to. Ask the other project's main agent only about decisions purely about its own project.
- The main agent reaches other projects through its secondary; `tmux-ask --any` only when the user asks.
