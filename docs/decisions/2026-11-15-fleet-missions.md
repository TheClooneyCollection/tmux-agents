# Optional fleet missions for agent chains

The user wants Agent Fleet Command to track chain goals and instructions while retaining ordinary tmux messaging.

When `fleet-command` is on PATH, follow the `missions` skill by name. Main creates missions and sends direction to secondary; secondary reads its inbox, owns mission status and ownership, records decisions and replies through Fleet Command. Workers append progress, handoff and completion logs. Each role uses its own recorded agent name.

Without the command, chain behavior stays unchanged. A hard dependency and replying to fleet instructions through tmux messages were rejected: installations without the dashboard must keep working, and fleet replies must clear the instruction inbox.
