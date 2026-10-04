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

- **Main agent** (the agent the user started, usually Claude). The agent that receives "start the chain" is the main agent. It talks to the user and the other agents: it clarifies intent, turns it into self-contained tasks and relays the user's decisions. It doesn't investigate or implement.
- **Secondary** (Claude). Coordinates the worker and owns the main checkout. It merges the worker's commits, runs the project's steps (importers, backups, server relaunches, tests) and records decisions in docs. Anything that needs a user decision goes to the main agent, not to the user.
- **Worker** (Codex by default, plus its own sub agents). The main implementer. By default it splits a task with independent parts across its own sub agents (`tmux-spawn`), one per part by file ownership, after agreeing the interfaces between them, then integrates and runs the full checks itself. It works alone only on short, strictly sequential or same-file tasks, and says why.

The worker's agent is `codex` unless the user has named another (another agent kind, or a Codex profile from `@tmux_agents_codex_homes`, e.g. `codex-work`), for example in their CLAUDE.md or AGENTS.md. Use theirs if so.

## Starting the chain (main agent)

`<me>` is your current name (`tmux-peers` shows it).

1. `tmux-rename --from <me> <me> main` renames you to `<kind>-<project>-main`. Use the new name as `<me>` from then on.
2. Spawn the secondary to your right:

   ```sh
   tmux-spawn claude --from <me> --split <me> --right --name secondary <<'MSG'
   You are the secondary in the agent chain (agent-chain skill). Main: <me>.
   Current goal: <goal>
   MSG
   ```

3. Spawn the worker for the secondary, below it:

   ```sh
   tmux-spawn <worker agent> --from <me> --for <secondary> --split <secondary> --below --name worker <<'MSG'
   <Brief for the secondary: the worker's role and its first goal.>
   MSG
   ```

   The worker becomes the secondary's sub agent, connected to the secondary only (not to you), and starts without a task. The secondary gets the brief, introduces itself to the worker (including that it is the worker in the agent chain and splits independent parts across sub agents by default) and sends the first task.
4. Tell the user the three names. The layout, all in your window: you on the left half, the secondary top right, the worker bottom right.

Spawn both from the main agent, not the worker from the secondary, so the worker stays at depth 1 and can still start its own sub agents; `--for` makes it the secondary's all the same. The main agent doesn't message the worker; it goes through the secondary (`tmux-ask --any` only if the user asks). Each brief names the agent's role in the agent chain, so it loads this skill; beyond that, it only needs the other agents' names and the current goal.

## Ending the chain

`tmux-dismiss --from <me> <secondary>` closes the secondary, the worker and the worker's sub agents. Each can be reopened with `tmux-spawn --resume <name> --from <me>`.

## Messages

- Everything goes through `tmux-ask`. Long reports go in a file; the message is a short summary plus the path.
- The user reads the secondary's messages to the main agent directly, so the main agent doesn't restate them; it brings up a decision as a one-line summary plus options.
- Send FYIs as notices (`tmux-ask --notice`), not requests: a request makes the receiver work again and the sender wait for a reply, even if it says "no reply needed". A decision request states the default and what is blocked meanwhile.
- Reply as soon as a request's main work is done (e.g. the release is out). Don't hold the reply for follow-ups such as a deploy going live; send those later as notices. For a request with several parts, send a notice as each part lands.
- An instruction the user gives directly to any agent wins; that agent tells the others what changed.

## Working across projects

Whenever work crosses project boundaries:

- Each project's secondary is its interface to other projects. Cross-project requests go secondary to secondary, never straight to another project's main agent or worker. If that project has no chain, talk to its main or current agent.
- Requests are self-contained (goal, paths, constraints, deliverable); the receiving project decides how and who does it.
- Agents only edit their own project's files. Changes elsewhere are requested from that project's agents.
- User decisions go back up the requesting chain to its main agent, the one the user is talking to. Ask the other project's main agent only about decisions purely about its own project.
- The main agent reaches other projects through its secondary; `tmux-ask --any` only when the user asks.
