# Shell panes in project popups

**Context.** Users and agents need an interactive project shell they can leave running and revisit through the existing popup list.

**Decision.** Add `tmux-shell [--from AGENT] [--client CLIENT] [--pane OPENER]` and the user binding `prefix + C-s`.

- The default shortcut is `prefix + C-s`. Configure `@tmux_agents_shell_key` before sourcing the configuration; nonempty `TMUX_AGENTS_SHELL_KEY` overrides it. `none` disables, while empty values fall through. Re-sourcing applies changes and removes the old key only if it still holds our binding.
- Create a shell in the hidden `agents-<project>` session and open its popup immediately. `prefix + d` detaches the popup while the shell keeps running.
- User-created shells are independent, even when opened from an agent pane. `--pane` selects the opener and working directory, never ownership. Independent shells belong to the opener's window scope in the list.
- Agents always use `--from NAME`. This explicitly gives the shell an owner; recursively dismissing that owner closes its shells too.
- `prefix + a` shows shells distinctly alongside agents. Enter reopens the live shell popup; `ctrl-x` closes it.
- Shell exit removes the pane entirely. There is no closed shell record, resume workflow, agent state, task protocol, permission state or worked-time accounting.
- Command history follows the configured shell's ordinary history settings. There is no dedicated saved-command log, and forced closure may lose history that the shell has not written.

**Why.** Reusing the project session and list provides a persistent interactive terminal without adding agent lifecycle semantics to a shell. Explicit ownership keeps user shells independent and lets agent cleanup cover resources it owns.

**Rejected.** `prefix + s`, which would replace tmux's default session picker; inferring ownership from the opener; preserving closed shell records, capturing shell output for later recovery or inventing a separate command-history store.
