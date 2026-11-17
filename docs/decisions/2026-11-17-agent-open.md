# Open a named agent for the user

## Context

An agent coordinating work needs to show another live agent's pane without asking the user to find it in the list.

## Decision

Provide `tmux-agents open NAME --from ME`. Resolve the exact live name and choose the most recently active client attached to the caller's session. Open hidden agent sessions with the existing popup viewer; switch the client directly for visible sessions. Report success on one line and fail for missing agents or clients.

## Rationale

Session-scoped client selection follows the caller's user while preserving the list's familiar viewing behavior. Do not select a client from an unrelated session or require a peer connection merely to view a pane.
