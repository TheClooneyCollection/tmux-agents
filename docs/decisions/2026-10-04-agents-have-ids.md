# Agents have hidden ids; names are labels

**Context.** Everything that refers to an agent across time used its name: session records were files named after it, `parent=` in them, the `@awaiting` and `@closed` lists, and queued messages' `.meta`. So a name could only belong to one agent, live or closed: spawning a name held by a closed agent's record overwrote it (its conversation could no longer be reopened, and its closed children were attributed to the new agent), and renaming had to rewrite every reference.

**Decision.** Every agent gets a unique id when it's created, hidden from the user. Everything that indexes agents uses the id; the name is only a label.

- **The id.** `a` + 12 random hex digits (e.g. `a3f09c41b2d7e`), stored on the pane as `@agent_id`. Assigned when a pane first gets a name: `tmux-spawn` (including `--for` and `--split`), `tmux-connect` (and its auto names), `tmux-rename` of an unnamed pane. A reopened agent keeps its id: it's the same agent.
- **Names.** Unique among live agents, as now. A closed agent's name is free to reuse; closed agents may share names with each other and with a live one. Commands that take a name (`tmux-ask`, `tmux-peek`, `tmux-connect`, `tmux-dismiss`, `tmux-rename`) resolve it among live agents, as now.
- **Session records** are files named by id: `sessions/<agent id>`, with `name=` (the label at closing) and the existing keys. `id=` keeps meaning the Claude/Codex conversation id. `parent=` holds the parent's agent id, with `parent_name=` for display.
- **Other references** use ids: `@awaiting` and `@closed` hold agent ids (shown as names); queued messages' `.meta` gets `from_id`/`to_id` next to the names; redelivery on reopen matches `to_id`. Live links (`@peers`, `@parent`) stay pane ids, which are already unique on a server.
- **Renaming** changes the label (`@agent`, and `name=` in its record if it has one) and sends the same notices; nothing else needs rewriting.
- **Reopening.** `tmux-spawn --resume-id <id>` reopens that exact agent. `tmux-spawn --resume <name>` reopens the one closed agent with that name; if several closed agents have it, it refuses and lists them (id, when closed, parent, project) so the caller picks with `--resume-id` (see open question 1). If a live agent holds the name, a reopened agent with the same name gets `-2`, `-3` for as long as both are live. The agent list's closed section keys entries by id internally (so Enter always reopens the right one); when closed agents share a name, its second line tells them apart by closed time, parent and project.
- **Migration** runs once per tmux server, on the first command that needs it, under the identity lock, and is idempotent (marker file `sessions/.ids-v1`): every live named pane without `@agent_id` gets one; every name-keyed record gets an id and is rewritten as `sessions/<id>` with `name=<old file name>`; `parent=<name>` becomes the id of the live pane or record with that name (unique, since names were unique when records were keyed by them), keeping `parent_name=`; `@awaiting`/`@closed` names and `.meta` names become ids the same way. Nothing is deleted until its replacement is written; conversation ids (`id=`) are copied as they are, so every resumable conversation stays resumable and parent links survive. Unresolvable names (a parent that's gone with no record) keep `parent_name=` only, as today's records effectively do.
- **Budget.** The list build reads `@agent_id` in its existing pane snapshot and the records in its existing single read; no extra processes per agent.

**Why.** It removes a class of bugs instead of patching one: names can't collide with history, renaming can't leave stale references, and a closed agent can always be reopened exactly.

**Ids are for agents, not the user** (the user's answer). `prefix + a` never shows an id in its rows; rows with repeated names are told apart by closed time, parent and project. The preview panel of a selected closed agent may show its id (the user's clarification). Agents get ids from commands:
- `tmux-peers --ids` adds an id column.
- `tmux-spawn --list-closed` lists the closed agents that can be reopened: id, name, closed time, parent, project.
- `tmux-spawn --resume <name>` with several closed agents of that name refuses and lists them the same way, so the caller picks with `--resume-id <id>` (the user's answer; guessing could reopen the wrong conversation).

Released as minor, v1.9.0.
