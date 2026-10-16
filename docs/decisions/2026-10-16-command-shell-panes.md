# Commands in shell popups

## Context

Users need to pick or type a short command, watch it run, and keep its result visible without leaving successful commands in live terminals.

## Decision

- `prefix + C-s` opens a newest-first, deduplicated fish, bash or zsh history picker. Enter chooses a history entry, or accepts a query with no matching entry. Alt-Enter always accepts the query. Cancel creates no pane.
- `prefix + S` opens a plain shell. Keep `@tmux_agents_shell_key` for that mode with the new default `S`; add `@tmux_agents_command_key`, default `C-s`. Both have environment overrides, support `none`, and apply before sourcing the configuration with safe rebind cleanup.
- Agents use `tmux-shell --from ME --command CMD` directly; plain `tmux-shell --from ME` remains available. Run command text through the configured shell, preserving its syntax and functions, in the opener's directory.
- Exit zero shows `ok` and a visible countdown, default three seconds. Any key cancels automatic closure and opens an interactive shell. Nonzero shows `failed N` and immediately opens an interactive shell. `shell_close_secs` is a nonnegative integer; zero closes successful commands immediately.
- Show command and status in the list. Completed command records persist after the pane closes until `ctrl-x` clears them; they cannot be resumed. Clearing a live command closes it too. Recursive owner dismissal clears owned commands and their records.
- User-created panes are independent; `--from` assigns ownership. Command panes retain all plain-shell message and agent-target guards, with no agent work accounting.
- Read command records and agent records in one batch alongside one pane snapshot. Batch pane-option updates and schedule the popup before label refresh to reduce startup calls.
- Use the configured fish shell’s `history --null` for fish history and Perl for bash/zsh files, avoiding a new Python runtime dependency. Fish runs its non-interactive startup configuration; history entries are data, not executed commands. Keep ordinary interactive shell history behavior; do not capture terminal output or introduce resumable command sessions.

## Why

A successful command can clean up its terminal while retaining a small result row. Failed commands leave output and a prompt ready for investigation. Explicit clearing controls record lifetime, and existing shell ownership and safety boundaries remain consistent.

## Rejected

Do not send command text with agent messages, auto-close failed commands, reuse agent conversation records, or silently reopen completed commands.
