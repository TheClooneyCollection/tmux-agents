# Spawn inherits the caller's Codex profile

A helper launched by a second-account Codex agent started on the default account because the shared tool process exposed plain `codex`. The live caller already had its profile in its session record.

## Decision

When `tmux-spawn` omits the agent argument, use the named caller's recorded agent kind/profile. For unrecorded callers, retain environment and pane-command detection, including a configured `CODEX_HOME` when the kind is plain Codex. `--for` changes ownership, not the source of this default.

Resume uses the saved kind/profile, falling back to the live parent when no kind was recorded. An explicit agent always wins and becomes the resumed record's kind for subsequent resumes. Plain `codex` uses the default home even if the tmux server has another `CODEX_HOME`.

## Why

The session record belongs to the named caller; a shared daemon's environment can belong to another account. Keeping the profile on resume keeps the conversation in the account that created it.

## Rejected

Always choosing plain Codex, or trusting the shared process before the caller's record, can silently switch accounts. Inferring a profile from the display name is unreliable because names can change.
