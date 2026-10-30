# Resumed Codex conversations bind to the current live identity

A conversation resumed with `tmux-agents start codex -- resume` gets a new
agent identity. A closed record may still contain its Codex thread ID.
Previously that historical record discarded completion notifications before
the verified current identity could bind the thread, leaving work running.

An explicit notify agent ID that resolves to a live pane can bind the thread
when historical owners are explicitly closed and have no live pane. An
unclosed record with a missing pane still rejects takeover. A different live owner, or a
conflicting thread on the explicit pane or its record, still rejects the
notification. Late callbacks carrying a closed agent ID are rejected. Legacy
notifications without an explicit ID retain their closed-record guard.

This restores completion routing and normal state and worked-time accounting.
Historical records and counters are preserved; no past work is reconstructed.
Rejecting every previously recorded thread would break intentional resume;
unconditionally preferring an explicit ID would allow live-owner conflicts.
