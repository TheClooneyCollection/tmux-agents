# Done keeps the last report visible

The user chose to keep a completed agent’s last progress report visible in both list rows and the status chip.

Display nonempty activity as `done · <text>` when the displayed state is done. With no report, keep the existing `no report yet` list activity and plain `done` chip, without a dangling separator. Prefix before the existing display-width truncation; retain the list’s Unicode handling and the chip’s native tmux clipping. Other states and stored `@activity` are unchanged.

This keeps completion and its useful context together. Replacing the report with only `done`, changing only one view, and rewriting stored activity were rejected.

## Superseded in part (2026-11-14)

Under [Retire the request ledger](2026-11-14-retire-request-ledger.md), a progress report from a `done` agent moves it to `working`, because a report is evidence of a running turn. After its turn ends, `done · <report>` still shows as described here.
