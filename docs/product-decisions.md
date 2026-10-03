# Product decisions

Decisions the user made about how tmux-agents should behave, with the reasoning, so later changes don't undo them by accident. Newest first. Technical details live in [DESIGN.md](../DESIGN.md) and [docs/design](design/).

## 2026-10-03: Spawning an agent for another agent (`tmux-spawn --for`)

**Context.** In an agent chain (main → coordinator → worker), the worker should report to the coordinator, not to main. But if the coordinator spawns the worker, the worker sits at depth 2 and can't start sub agents of its own (`TMUX_AGENTS_MAX_DEPTH`, default 2). So main spawns both, which today connects the worker to main as main's sub agent, and the coordinator has to connect to it separately.

**Decision.** `tmux-spawn --for <name>` lets an agent spawn a sub agent that belongs to another agent:

- **It belongs to `<name>`.** Its parent is `<name>`: it is connected to `<name>` only, it shows under `<name>` in the agent list, it reports to `<name>`, and `<name>` closes it.
- **It is not connected to the caller.** Main and the worker have no link.
- **Depth comes from the caller.** A worker spawned by main (depth 0) is at depth 1, so it can still start its own sub agents. `--for` changes who owns the agent, not how deep it may go: the depth limit still applies to whoever runs `tmux-spawn`.
- **`<name>` must already be connected to the caller**, so an agent can't hand sub agents to agents it doesn't work with.
- **The first message comes from the owner, not the caller.** The new agent starts without a task. The caller tells the owner that the new agent is now connected to it, and passes along any brief it has for it. The owner then introduces itself to the new agent and sends it its first task.
- **`tmux-ask --any` is unchanged.** As before, an agent may message a named agent it isn't connected to only when the user asks, so main can still reach the worker that way if the user wants it.

**Rejected.**

- *The caller sends the first task, with reply instructions pointing at the owner.* Rejected: the worker should start its relationship with the agent it works for, and hear its first task from it.
- *Raising the depth limit so the coordinator can spawn the worker itself.* Not chosen for this; the limit guards against runaway spawning and keeps every agent within reach of the user. It stays configurable.
- *Spawning normally and then disconnecting main.* Leaves main as the worker's parent, so replies, the list and cleanup would still point at main.

**Why the depth limit is 2 (for reference).** Not measured; a conservative default. Each level multiplies agents, tokens and cost, adds relay latency and lost context, and moves the user further from the agents doing the work. Two levels let an agent split work and its sub agents split once more.
