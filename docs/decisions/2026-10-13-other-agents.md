# Limited support for other agents

## Context

Users want to launch other coding agents wherever an agent kind is accepted,
without pretending those commands have Claude or Codex integrations.

## Decision

Accept an executable command basename on PATH in start, spawn and all chain
roles. Configured Codex profiles win over a same-named executable. Validation
does not run the command; shell syntax and paths are not agent kinds.

Claude, Codex and configured profiles retain their full adapters. Other commands
receive no initial task argument, automatic permissions, hooks or identity pins.
They are untracked, have no worked-time clock and cannot resume saved records.
After launch the caller sends the first task manually with tmux-ask once the
agent is at its prompt. Spawn's existing result tells callers when a supplied
task was not sent.

Document the subset in [Supported agents](../agents.md), including uncertain
TUI delivery and chain main/secondary skill limitations. Keep the existing
parent waiting behavior. Welcome contributions adding full adapters.

## Scope rejected

No ready command, delivery settings, support columns, command:NAME selector,
new task flags, parent-waiting redesign or stderr support notices. A TUI may
erase a notice immediately. This is a minor feature release; full adapters
remain unchanged.
