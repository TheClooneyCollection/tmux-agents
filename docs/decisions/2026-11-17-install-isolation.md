# Isolate trial installations

Use `install.sh --home DIR` for trial installations, especially linked worktrees.
An inherited Codex profile once relinked a real account to a temporary worktree:
an empty account map fell back to the user’s tmux settings.

Sandbox installs set HOME for the entire run, filter inherited destinations to
that home and skip state migration. Every installer run uses a private switch to
resolve accounts from the environment alone; runtime tmux fallback stays unchanged,
including for empty account maps exported into running agents. Ordinary installs
refuse linked worktrees or outside-home destinations before writing, including dry
runs; compare physical Git directory paths so a tarball copy inside another repo
is accepted. `--force` is the explicit override for normal installs and also backs
up and replaces conflicting real files. Outside-HOME Codex accounts need it.
Sandbox directory symlinks cannot escape HOME, and HOME resolving to `/` is always
refused because it would make containment checks meaningless.
