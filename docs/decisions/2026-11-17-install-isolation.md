# Isolate trial installations

Use `install.sh --home DIR` for trial installations, especially linked worktrees.
An inherited Codex profile once relinked a real account to a temporary worktree:
an empty account map fell back to the user’s tmux settings.

Sandbox installs set HOME for the entire run, filter inherited destinations to
that home and skip tmux account discovery and state migration. An explicitly
empty account map disables tmux fallback in all callers. Ordinary installs refuse
linked worktrees or outside-home destinations before writing, including dry runs;
`--force` is the explicit override. Sandbox directory symlinks cannot escape HOME.
