# Quiet agent notes and idle digests

Date: 2026-11-16

## Context

Each progress notice pasted into the main agent starts another turn. Relaying those updates into chat floods the user's phone, even when no answer or decision is needed. The main still needs enough context to explain progress when asked or at a natural pause.

## Decision

The user chose three rules:

1. Name the quiet category `--note`. Progress, handoff updates, partial completion and plan updates use it. The "stopped without replying" reminder also becomes a note; reply obligations and their list display stay unchanged.
2. Enable idle digests by default at roughly five minutes. `@tmux_agents_notes_digest_secs` / `TMUX_AGENTS_NOTES_DIGEST_SECS` defaults to `300`; `0` disables digests. Skip working, needs-you and permission states. Announce a new unread batch after each idle interval, independently of the chip. Successfully delivered digest batches become read. Subsequent digests contain only new notes and begin `Continuing from last update ...`; no new notes means no digest.
3. Keep awaited results and anything requiring the user on ordinary replies, requests or notices. Release completion, CI failure, push approval and decisions must never be quiet notes.

Notes form an immutable append-only log with increasing IDs and one read cursor per receiver. Unread means after that cursor; reads and successful digests advance it to the last displayed note, while hook summaries and `--keep-unread` do not. Notes are stored by receiver agent ID without pasting or starting a turn, including for closed records. `tmux-notes --from ME` reads and marks unread notes; filtering, read-history, count and keep-unread modes support inspection. Notes and summary attachments have seven-day retention, and attached full text remains available through `tmux-read`.

Claude receives an unread summary through its prompt hook; Codex checks notes at each turn start. Hook summaries leave notes unread; successful digest delivery marks only its included notes read. Main summarizes useful points when asked or at a natural pause. Optional Fleet progress logging does not make delivery depend on Fleet.

The optional unread badge is omitted to preserve the list build budget. Rename and folder-trust notices remain immediate ordinary system notices.

## Rejected alternatives

- Hold notices while busy: each still creates a separate turn when released.
- Silence every notice: rename and rule changes would lose timely delivery.
- Use Fleet inbox as the only channel: this adds a service dependency to core messaging.
