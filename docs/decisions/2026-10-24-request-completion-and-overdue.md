# Request completion and overdue replies

## Context

A completed stone-age worker answered a request from a nonparent agent. The reply arrived successfully, but the parent-only completion rule left the worker working. Its Codex completion notification then marked it `needs you`, although the requested work was finished.

## Decision

The user approved request-based completion on 2026-10-24:

- Each request has a unique identity and stable requester and receiver IDs. Replies resolve the corresponding request, including repeated or concurrent requests between the same agents.
- Completion does not depend on the ownership relationship. Once all incoming requests are answered and no other work remains, return to the appropriate completed or idle state.
- Preserve active parent tasks, local work, background waits and every other outstanding request. Answering one request must not finish unrelated work.
- Waiting for another agent is waiting. An agent ending a turn with unanswered requests and no agent or background wait needs the user.
- Overdue replies are a separate `reply overdue` condition, not `needs you`. Inspect the receiver's work/progress where available; elapsed task duration alone does not mean it is blocked. Provide a configurable inactivity timeout with a documented default.
- Keep existing CLI workflows compatible, including queued delivery, retry, resume and rename. Exact request association must remain possible when several requests share the same pair of agents.

Routine implementation choices, timeout defaults and compatibility details may be resolved without another user decision. Document the final mechanics and limitations in the design and user guides. Preserve the list's single pane snapshot and batched record-read budget.

## Why

Ownership describes lifecycle and cleanup, while the request identifies the work being answered. Separate request completion and overdue attention avoids false user alerts without hiding unfinished work.

## Rejected alternatives

- Marking every reply done, which can swallow another requester or parent's active task.
- Treating a timeout as `needs you`, which confuses slow or ongoing work with a request for human intervention. Optional timeout escalation was discussed but was not selected.
- Changing live agent states as part of this implementation. This task authorizes implementation and validation only, with no release or installation update.

## Follow-up (2026-10-24 review)

A review of the implementation found three groups of problems; the user asked for all of them to be fixed:

- Ledger bookkeeping after a successful paste or spawn was fatal under `set -e`. A `delivered` error re-queued the pasted request every retry, or closed a new pane before its agent started. Those calls are now best effort, and a request publication the ledger rejects removes its own staged files.
- Completion could get stuck: a pending request to a receiver that no longer exists blocked its requester forever, and local work inferred from a user prompt was never completed unless the agent called `--local-done`, so every top-level session without the skill ended each turn as `needs you`. Inferred local work now ends with its turn when nothing else is outstanding; only explicit `--local` requires `--local-done`. Outgoing waits count live receivers only. A top-level agent's restore base is `idle`, never the sub agent `done`.
- Each turn end ran three ledger processes and parsed the Codex notify payload three times. The turn end is now one ledger operation and one parser, and free-text pane options are tab free so the ledger's pane snapshot cannot be shifted.
