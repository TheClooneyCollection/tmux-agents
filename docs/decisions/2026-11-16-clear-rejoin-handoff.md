# Rejoin roles and select handoffs after a clear

**Superseded (2026-11-17).** The separately maintained wrap-up skill now owns resume after a context clear. The agent-chain rejoin flow and its triggers are retired; see [Streamlined commands](2026-11-17-streamlined-commands.md). The original decision below is historical.

## Context

The user clears agent contexts manually and wants a short instruction to restore the existing chain. Some outcomes should be recorded, some tasks continued and others left behind. Restoring the chain must not silently restart all old work.

## Decision

Recognize "cleared, resume please" and "清完了，继续" in the agent-chain skill. Recover the trusted identity and existing connections. Main restores secondary's role; secondary restores worker's role. Secondary and worker wait for assigned work and report surviving work rather than recreating it.

Reuse wrap-up for the user's numbered selection before a clear. Store the selected handoff in a temporary project-root `HANDOFF.md`, locally excluded from Git and never committed. Main reads it after a clear, continues explicitly selected work and offers the remaining important items for selection. Missing handoffs are reported rather than reconstructed from guesses.

Remove entries after completion, explicit dismissal or transfer to a user-approved durable record. Delete `HANDOFF.md` when all entries are handled; reading alone does not consume the handoff. Preserve unrelated contents and do not overwrite a tracked file.

Main refreshes the existing, uniquely matched main-sequence agent row's `resume=` with the verified new conversation ID using the existing `set` command, then checks `list`. Claude can do this after its prompt hook; Codex must wait for its first new-thread turn end, with secondary completing the update after main's turn or main retaining a pending item for its next turn. Never write an unconfirmed old ID, create an unrequested row or change shell/command rows.

## Why

A short trigger is enough to restore roles without requiring the user to recite the chain procedure. A temporary file survives context loss while keeping unfinished choices separate from authorization to act.

## Rejected

- A new automatic context-clearing command or a replacement handoff tool.
- Automatically continuing every task mentioned in the old conversation.
- Committing temporary handoffs or deleting them immediately after reading.
