# Visible sub agents return to a shell

## Context

A visible split belongs to the working layout. Leaving a dead agent in that split makes the user create another shell before continuing there.

## Decision

New `tmux-spawn --split` panes return to tmux's `default-shell` when the agent exits. `@tmux_agents_sub_exit` selects `shell` (default) or `keep`; nonempty `TMUX_AGENTS_SUB_EXIT` overrides the option. Unknown values fail before launch.

In `shell` mode, save worked time, close the session record, notify and disconnect peers, detach direct children, and clear the pane's agent state before starting the shell. Cleanup checks the original agent ID so an old process cannot erase a replacement identity. Do not enable `remain-on-exit` for these splits.

The returned shell restores the pane's environment from before launch preparation, preserving unset variables, empty values and the exact `PATH`. Profile `CODEX_HOME`, agent identity pins, chain role overrides and launch path prefixes apply only to the agent. The split depth counter must not survive in the returned shell: normally `TMUX_AGENTS_DEPTH` is unset there; an explicitly preexisting value is restored. The same environment boundary applies to the outer shell of `start chain`, after its child launcher exits.

`keep` retains the dead split and its transcript, using the existing `pane-died` work-saving hook. Hidden spawns and resumed agents keep that behavior regardless of this preference. Top-level `start` cleanup stays unchanged.

## Why

The default keeps a visible pane useful after its task finishes, while retaining its closed conversation for later reopening. Users who prefer the dead transcript can select `keep`.

## Rejected

Changing hidden or resumed agents to shells would leave unnecessary hidden shells. Killing visible splits would change the user's layout. Clearing state without checking identity could erase a newer agent in the same pane.
