# Resume only the chain main

The user wants a new chain window to retain the main conversation while creating fresh secondary and worker members.

`tmux-agents start chain --main-resume ID` resumes the selected main. Claude starts with `--resume ID`, waits for its input prompt, submits literal `/rc` and Enter, then receives the chain brief. The brief is not a launch argument because it would start a working turn before `/rc`. Codex and configured Codex profiles launch `resume ID` with the usual brief, without `/rc`.

The option accepts a conversation UUID found in the selected session store. Missing, malformed, unknown and wrong-kind IDs warn on stderr and fall back to a fresh main, as do unsupported executables. They never prevent window creation. Without the option behavior is unchanged, and stdout stays exactly the new pane ID plus newline. Role choices, flag order and chain naming retain their existing semantics.

Resuming all members or failing the chain launch on a bad ID was rejected: only the main's context should persist, and an unavailable conversation must not block a fresh chain.

## Configured project launchers

Move the former personal main-sequence and chain wrappers into tmux-agents, sharing one parser and delegating chain startup to `start chain`. Every sequence window comes from ordered project records, including optional named shells; there are no built-in project paths. Session `main` remains the default, but the scan root has no default and setup asks for it.

Use an XDG tmux-agents project file, with read fallback to the former main-sequence path until the new file exists. Preserve duplicate directories, comments and order. `list`, `add` with optional 1-based `--at`, and unambiguous `set`/`unset` give agents the same editing interface as users. Setup offers candidates, user ordering, optional named shell placement and custom window names; it does not collect resume IDs. Dotfiles migration remains a separate task.
