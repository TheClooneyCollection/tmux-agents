# Queued and undelivered messages can be listed and retried

**Decision.** `tmux-ask --pending` lists queued and undelivered messages (time, sender, receiver, state, path), including `.undelivered` files left by older versions, which have no metadata and are read from their header line. `tmux-ask --retry [--to NAME]` re-sends undelivered messages whose receiver exists now (by name), through the normal path, so they queue if the user is busy; any it can't place stay and are reported.

Each queued message gets a `.meta` file next to it (`key=value`: `from_pane`, `from_name`, `to_pane`, `to_name`, `kind`, `queued_at`) so these commands, the bounce and redelivery on reopen know who it was for.
