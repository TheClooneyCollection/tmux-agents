# Targeting and naming chain windows

## Context

Shell automation needs to start a chain in a chosen existing tmux session and retain a predictable window name, including when launched outside a tmux pane.

## Decision

- Extend `tmux-agents start chain [DIR]` with `--target session[:index]` and `--name NAME`. Options and DIR may appear in any order alongside the existing role flags.
- With a target, create a detached window in the existing session. A bare session selects its next free index; an explicit index must be available. A reachable existing server is sufficient, without a caller pane or `TMUX` variable.
- Without a target, keep opening and focusing a new window in the current session.
- Name the window from `--name`, otherwise from DIR's basename, using `root` for `/`. Disable both `automatic-rename` and `allow-rename` before starting the agent. This window name is separate from `start AGENT --name`, which labels a pane.
- On success, stdout is exactly the new pane ID plus a newline. Errors use stderr and a nonzero exit status. Validate all role choices before creating a window.
- Preserve main-role selection, instruction-file member preferences and the existing chain workflow. Saying “start the chain” to a running agent keeps that agent as main.
- Select a named server through the `TMUX` socket path or a `tmux -L NAME` wrapper. Add no socket flag and make no command-record changes.

## Why

A detached target supports shell automation without moving the user's focus. Stable window names and a single pane ID on stdout let callers identify the launch. Existing invocations keep their current placement behavior.

## Rejected

Do not overload the chain window name as the main agent's pane label, create sessions implicitly, or add a separate socket-selection interface.
