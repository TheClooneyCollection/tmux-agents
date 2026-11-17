# needs-you vs permission for AskUserQuestion (investigation, no code changed)

## How states are derived (Claude)
- `--settings` hooks injected by `tmux-spawn --run` (bin/lib.sh ~1629):
  - `PreToolUse` -> `tmux-agent-report --tool-start` (reads stdin; `tool_name":"AskUserQuestion"` -> asking) -> `@asking=1`, `@attention_since`, `@state=needs_you` (bin/tmux-agent-report:62-102).
  - `Notification[permission_prompt]` -> `--perm on` -> sets `@perm_since` only (tmux-agent-report:~300).
  - `PostToolUse`/`PostToolUseFailure`/next `PreToolUse` -> clear `@perm_since`, `@asking`.
- Display: `live_status` in bin/tmux-agents-list.awk:214 checks `perm[p]!="-"` BEFORE `state==needs_you`, so any `@perm_since` shows `⚠ permission`. Chip in bin/tmux-agents:259 does the same (`NEEDS PERMISSION`, red).

## Why AskUserQuestion lands in permission
Most likely cause (inferred from code; not reproduced against a live Claude): AskUserQuestion is a tool that requires user interaction, so Claude's permission path for it emits `Notification` with `notification_type=permission_prompt` (the same "needs your permission to use AskUserQuestion" idle/permission notice, after Claude's ~6s gate). Sequence: PreToolUse sets needs_you+@asking, then the notification fires `--perm on`, setting `@perm_since`. Display precedence then shows permission, and the chip goes red. The existing tests (tests/needs-you.sh:170-190) only cover tool start/end, never `--perm on` while `@asking=1`, so this combination is untested. Docs (sub-agents.md:127-128) say the six-second gate applies to notifications, consistent with the symptom appearing only if the user takes >6s.
To confirm cheaply: while a question is open, `tmux show -p -t <pane> @asking @perm_since @state`; expect all three set.

## Smallest fix
In `bin/tmux-agent-report`, `case "$perm" in on)`: if `@asking` is `1`, do nothing (exit 0). The question already holds needs_you; PostToolUse/next tool clears `@asking` as before. Alternative (also small, touches awk + bin/tmux-agents): rank `@asking` above `@perm_since` in display; the first is simpler and keeps the chip logic untouched.
Risk: a real permission prompt arriving while a stale `@asking=1` remains. `@asking` is cleared on tool events, turn start and end, so the window is small.

Files: `bin/tmux-agent-report` (perm on branch), `docs/design/sub-agents.md` (one sentence under "Claude questions"), `CHANGELOG.md`.
Tests (tests/needs-you.sh, near line 187): 
1. `tool start AskUserQuestion; --perm on` -> state needs_you, `@perm_since` empty; list status shows `needs you` (also tests/fzf-fields-style check of live_status if wanted).
2. `tool end AskUserQuestion` after that clears `@asking`, state working.
3. Regression: `--perm on` without asking still sets `@perm_since`.

## Codex
- Codex gets no hooks (bin/lib.sh:1645): only `notify` at turn end plus explicit `tmux-agent-report --needs-you`. It has no `@perm_since` path, so it cannot show "permission" for questions; it shows needs-you only if the agent reports it explicitly. No similar bug, but also no automatic question detection.
