# Show Codex startup folder trust as permission

## Context

Spawned Codex helpers in a new repository stopped at `Folder access` / `Trust this folder?` before executing their initial tasks. Spawn had marked them working, and no turn notification could reveal this startup wait. The user asked for a visible attention signal, without automatically trusting the folder.

## Decision

Recognize this startup confirmation for spawned Codex and profiles, show the existing permission attention, pause work timing, and notify the parent that execution has not started. The user opens the pane and makes the trust decision. Remove only the startup observer's own wait marker when the dialog ends.

## Why

The existing permission display puts hidden helpers in the attention section and makes the blocked startup visible without requiring the model to have started. Observation belongs to launch, not the performance-sensitive list build.

## Rejected

Automatically selecting trust, writing trust configuration, or bypassing the dialog would take the user's security decision away. Enabling runtime permission hooks again would mislabel internal auto-review as user attention.
