# Track manual clears and owned work

## Context

Manual Claude `/clear` and Codex `/new` are now supported. A Codex pane could retain its old thread binding and discard every later completion. Parents received stopped-without-replying notices while their workers were still working, and COMMAND displayed a launcher shell instead of the running agent.

## Decision

A valid notify agent ID resolving to a live pane is authoritative: bind its incoming Codex thread to the pane and resume record, then process that pane's turn end. Keep title notifications and missing live identities inert, and preserve legacy routing without a verified ID. Log binding changes. For the one verified old-to-new thread transition, finish the current turn even if its inputs omit the latest delivery token, remove that absent token, and neither settle nor notify the owed slot. Other notifications keep the stale-delivery guard. The user accepts that a just-delivered request may instead run in the following turn.

Defer unanswered-stop notices while a tracked, live, non-shell descendant is working, including members. Leave the notice unsent so a later stop can send it once. Prompt and delivery starts clear the previous activity; tools and progress reports keep the current turn's report.

Peers and connect show recorded agent kinds or profiles for tracked panes. Inspect their process trees to distinguish a live executable from `(exited)`; shell and untracked panes retain their raw foreground command. Type shortcuts use the same source.

## Why

Conversations can change without changing the pane's identity or ownership. A working descendant is evidence that owned work continues. Foreground shell names alone do not establish that an agent has exited.

## Rejected

The user rejected previous-thread slots and live-owner conflict refusals for verified-ID notifications. Notifications without a verified identity keep their stricter routing guards. Automatically clearing sessions remains outside this workflow.
