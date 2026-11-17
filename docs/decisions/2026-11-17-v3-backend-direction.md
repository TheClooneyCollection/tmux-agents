# v3 direction: pluggable backends under a new name

The user's idea for v3: keep today's CLI but stop requiring tmux, so any
backend can power it through an adapter, and rename the product away from
"tmux-agents". Research: [v3-backend-adapter.md](../research/v3-backend-adapter.md).

Decision (user, 2026-11-17):

- The first non-tmux target is another terminal multiplexer, Zellij first.
  tmux plus a fake backend come before it.
- Backends declare capabilities and the UI degrades per backend. Missing
  popup, chip or interactive open reports unavailable instead of being faked.
- One backend per project at first. Mixed backends in a project can come later.
- A new, distinctive brand. "Agent Fleet" stays a description only; the sunset
  Agent Fleet Command keeps its `fleet`/`fleet-command` names and data, and v3
  imports none of it automatically.
- v2.0.0 ships the current tmux work unchanged. Preparation lands in v2.x stages
  as the research describes; the `tmux-*` commands stay as wrappers through v3.

Rejected: a fully headless PTY daemon as the first target (a separate, much
larger project); requiring full UI parity from every backend; mixed backends
from the start; reusing `fleet`, `agent-fleet` or the sunset Fleet identity.
