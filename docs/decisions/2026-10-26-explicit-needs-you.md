# Explicit user attention

## Context

Agents can need a user decision before their turn ends, including while a question form remains open. Previously `tmux-agent-report` could report background waiting, but could not explicitly request user attention. Both the default list admission filter and the status chip required ownership for ordinary needs-you states, hiding top-level agents.

## Decision

`tmux-agent-report [--from ME] --needs-you "reason"` puts a tracked agent in `needs_you` immediately and displays the reason as its activity. This explicit attention survives turn end and clears when work resumes through an ordinary progress report or turn start. It does not complete pending requests.

Tracked top-level agents in `needs_you` appear in the default list's global attention section and in the status chip. Ordinary top-level agents remain excluded, and untracked agents do not gain inferred attention. Existing permission and message-waiting rules remain unchanged.

Use `--needs-you` for a user question, choice or missing information. `--waiting` remains for background work or another agent, never the user.

## Why

Explicit user attention must be visible regardless of ownership. Requiring turn completion misses open question forms, and excluding top-level agents hides valid user decisions. Showing all top-level agents would add unrelated routine work to the helper list and chip.
