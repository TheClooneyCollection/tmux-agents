# Mission board in a pane

The user requested a read-only project mission view alongside live agent work.

`tmux-agents board [--watch [SECS]]` combines the project's state-directory
`missions/<project>/M<N>.mission` key=value records with a live owner/descendant tree. Unassigned
project agents remain visible, including when the directory or records do not exist. Rows show
short names, kind, saved model, shared list state and width-limited progress.
Watch defaults to two seconds and exits with q or Ctrl-C. Each refresh uses one
pane snapshot and reads needed records, without per-agent tmux queries.

This avoids maintaining a second mission store or inferring missions from
agent names. The existing agent list remains the source of state semantics.

The user replaced the original Markdown table source with the fixed mission
record format shared with the mission writer. Read records directly and ignore
legacy `board.md`; the view does not depend on the mission CLI.
