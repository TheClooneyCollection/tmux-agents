# Given names follow the naming format, with an opt-out

**Context.** Automatic names look like `claude-~-1`: `<command>-<dir>-<N>`. A name given with `tmux-spawn --name` or `tmux-rename` was used as is, so the same list mixed `claude-~-1` with `worker` and `spirit-earth`, and you couldn't tell from a name what kind of agent it was or which project it belonged to.

**Decision.** A given name is a short name by default and gets the same prefix as automatic names: `<command>-<dir>-<name>`, where `<command>` is the agent's own kind (`claude` or `codex`; a Codex profile counts as `codex`) and `<dir>` is its directory as automatic names show it (`~` for home). So `tmux-spawn codex --name spirit-earth` in `projects-stone-age` gives `codex-projects-stone-age-spirit-earth`. A name that already starts with that prefix is kept. Clashes still get `-2`, `-3`.

Users who want a name used exactly:
- `--exact` on `tmux-spawn` and `tmux-rename` uses the given name verbatim, once.
- A standing preference is a tmux option, set in `tmux.conf`: `set -g @tmux_agents_name_format exact` (default `prefixed`). The environment variable `TMUX_AGENTS_NAME_FORMAT` overrides it for a one-off. Order: environment, tmux option, default.

**Why `--exact`.** It says what you get. `--auto-name` would read as the opposite of what it does, since prefixing is already the default. One flag and one setting cover a one-off and a standing preference.

Everything that matches names keeps working: names are still unique words; `codex@project` and `codex`/`claude` matching look at a name's `codex-`/`claude-` start, which prefixed names have; agents use the names `tmux-spawn` prints.

**Why a tmux option.** It's where tmux-agents' other user settings already live (`@tmux_agents_chip_fps`), the user already edits `tmux.conf` to install it, it can be changed live with `tmux set -g` without restarting agents, and reading it costs one `tmux show` (or nothing, inside a snapshot). A separate config file would need a parser, a location and a reload story for no gain. The existing environment-only knobs (`TMUX_AGENTS_MAX_DEPTH`, `TMUX_AGENTS_RESUME_DAYS`, `TMUX_ASK_*`, ...) can move to the same scheme later.
