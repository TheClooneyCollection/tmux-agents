# Spawn arguments on resume

## Decision

Arguments after `tmux-spawn --` pass through to the agent and are saved with its session. On resume, omitting `--` reuses the saved vector. Supplying `-- ARGS...` replaces and saves it; a bare `--` clears it. This applies to hidden and in-place resume.

## Why

Appending on every resume duplicates flags and accumulates values such as `--add-dir`, with no way to remove a saved argument. Replacement gives callers control of the complete vector while preserving the convenient no-argument resume.
