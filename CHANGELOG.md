# Changelog

## v1.0.0 (2026-10-01)

First release, extracted from a dotfiles repo with its full history.

- **Connect panes.** `tmux-connect` names panes and links them; `prefix + A` connects from a picker. Agents can connect themselves ("connect codex and have it do xyz") with `tmux-connect --from`, which finds the other agent in the same window and names unnamed panes.
- **Messages.** `tmux-ask` pastes fenced requests and replies into a connected pane. Typing or scrolling in the receiver queues the message until you're done. Long messages are saved to a file.
- **Sub agents.** `tmux-spawn` starts Claude or Codex sub agents in hidden per-project sessions, in auto mode, connected to their parent, with a depth limit.
- **Agent list.** `prefix + a` opens `tmux-agents`: status, parent, project, current activity and a live preview. Open hidden agents in a popup, jump, dismiss, or clear finished ones.
- **Status chip.** An animated line above the status bar shows sub agents, with permission waits (red) and "needs you" (amber) taking focus.
- **Needs you detection** that knows when an agent is waiting on sub agents, sent requests, reported background work, or Claude background Bash commands.
- **Codex support.** Identity pinning wrappers for fish, bash and zsh, sandbox rules, and extra Codex accounts with `TMUX_AGENTS_CODEX_HOMES`.
- **Skills** for Claude and Codex, and `install.sh`.
