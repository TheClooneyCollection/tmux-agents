# Given names follow the naming format, with an opt-out

**Context.** Automatic names look like `claude-~-1`: `<command>-<dir>-<N>`. A name given with `tmux-spawn --name` or `tmux-rename` was used as is, so the same list mixed `claude-~-1` with `worker` and `spirit-earth`, and you couldn't tell from a name what kind of agent it was or which project it belonged to.

**Decision.** A given name is a short name by default and gets the same prefix as automatic names: `<command>-<dir>-<name>`, where `<command>` is the agent's own kind (`claude` or `codex`; a Codex profile counts as `codex`) and `<dir>` is its directory as automatic names show it (`~` for home). So `tmux-spawn codex --name spirit-earth` in `projects-stone-age` gives `codex-projects-stone-age-spirit-earth`. A name that already starts with that prefix is kept. Clashes still get `-2`, `-3`.

Users who want a name used exactly:
- `--exact` on `tmux-spawn` and `tmux-rename` uses the given name verbatim, once.
- `TMUX_AGENTS_NAME_FORMAT=exact` (default `prefixed`), in the environment or tmux's global environment like `TMUX_AGENTS_CODEX_HOMES`, makes that the default.

**Why `--exact`.** It says what you get. `--auto-name` would read as the opposite of what it does, since prefixing is already the default. One flag and one setting cover a one-off and a standing preference.

Everything that matches names keeps working: names are still unique words; `codex@project` and `codex`/`claude` matching look at a name's `codex-`/`claude-` start, which prefixed names have; agents use the names `tmux-spawn` prints.
