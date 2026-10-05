# User settings are tmux options

**Context.** Settings were environment variables scattered over the scripts, which had to be exported before tmux or an agent started, and couldn't be changed for agents already running. The name format was the first setting asked for as configuration.

**Decision.** Every user setting is a tmux option, set in `tmux.conf` (or live with `tmux set -g`): `@tmux_agents_<name>`. The old environment variables still work and win, for one-off use and backward compatibility. Order: environment, tmux option, default. The current settings, defaults and overrides are listed in [Configuration](../configuration.md), with commented examples in `tmux/tmux-agents.conf`. The README translations and guide link to that shared reference.

Internal variables (`TMUX_AGENTS_DEPTH`, `_KIND`, `_PINNED`, `_LIST_CLIENT`, `_SELECT*`, `TMUX_CONNECT_PANES`, `TMUX_ASK_IDENTITY_LOCKED`, the test hook `TMUX_SPAWN_BIN`) and internal options (`@tmux_agents_chip_pid`, `_main_format`, `_prefix_at`, `_list_mode`) aren't settings and stay as they are.

**Cost.** A script reads all `@tmux_agents_*` options with one `tmux show-options -g` call and caches them; the list build gets them inside its existing snapshot or that one call, within its process budget.

**Why tmux options.** See [given names follow the naming format](2026-10-04-names-follow-the-format.md): the user already edits `tmux.conf`, options change live, and a config file would need a parser and a reload story.
