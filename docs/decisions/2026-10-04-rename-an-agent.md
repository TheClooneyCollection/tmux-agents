# Renaming an agent

**Context.** The only way to rename was setting `@agent` (`tmux-connect --as`, the `prefix + A` form), which left everything that referred to the old name pointing nowhere: sub agents' parent links and session records, peers' border labels, other agents' `@awaiting` and `@closed` lists, queued messages, and agents still passing `--from <old>`.

**Decision.** `tmux-rename [--from ME] <agent> <new> [--exact]` renames in one step:

- **Name format.** `<new>` is a short name; the command builds the full one the way automatic names are built, `<command>-<dir>-<new>` (e.g. `main` → `claude-~-main`). If `<new>` already starts with that `<command>-<dir>-` prefix it's used as is; `--exact` uses `<new>` verbatim, and `TMUX_AGENTS_NAME_FORMAT=exact` makes that the default (see [given names follow the naming format](2026-10-04-names-follow-the-format.md)). Names in use are refused, and names are checked like any other (`valid_name`).
- **Who may rename whom.** An agent may rename itself and its descendants (`--from ME`, ancestry checked like `tmux-dismiss --from`). The user may rename any agent (no `--from`). Peers and unrelated agents are refused.
- **What follows the name.** Its `@agent`; its session record (the file is renamed); `parent=` in every session record that pointed at it; the word in every pane's `@awaiting` and `@closed`; `to_name`/`from_name` in queued and undelivered messages' `.meta`; the border labels of every connected pane (`refresh_labels`). `@parent` holds pane ids, so live links need no change.
- **Who is told.** The renamed agent gets a notice ("you are now X; pass --from X from now on"), and every agent connected to it gets one ("Y is now X"), from `tmux-rename`.
- **No alias.** The old name stops resolving at once; with the strict name lookup it fails loudly instead of reaching another pane, and the notices carry the new name.
