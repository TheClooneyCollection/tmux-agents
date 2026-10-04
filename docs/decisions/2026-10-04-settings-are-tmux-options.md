# User settings are tmux options

**Context.** Settings were environment variables scattered over the scripts, which had to be exported before tmux or an agent started, and couldn't be changed for agents already running. The name format was the first setting asked for as configuration.

**Decision.** Every user setting is a tmux option, set in `tmux.conf` (or live with `tmux set -g`): `@tmux_agents_<name>`. The old environment variables still work and win, for one-off use and backward compatibility. Order: environment, tmux option, default. All of them are listed in one "Configuration" section (README, README.zh-CN, docs/guide.md) and as commented examples in `tmux/tmux-agents.conf`.

| Option | Environment override | Default |
| --- | --- | --- |
| `@tmux_agents_name_format` | `TMUX_AGENTS_NAME_FORMAT` | `prefixed` |
| `@tmux_agents_max_depth` | `TMUX_AGENTS_MAX_DEPTH` | `2` |
| `@tmux_agents_codex_homes` | `TMUX_AGENTS_CODEX_HOMES` (also still read from tmux's global environment) | none |
| `@tmux_agents_session_prefix` | `TMUX_AGENTS_PREFIX` | `agents` |
| `@tmux_agents_resume_days` | `TMUX_AGENTS_RESUME_DAYS` | `7` |
| `@tmux_agents_preview_secs` | `TMUX_AGENTS_PREVIEW_SECS` | `0.5` |
| `@tmux_agents_blink_secs` | `TMUX_AGENTS_BLINK_SECS` | `60` |
| `@tmux_agents_chip_fps` | (already an option) | `10` |
| `@tmux_agents_ask_idle_secs` | `TMUX_ASK_IDLE_SECS` | `8` |
| `@tmux_agents_ask_copy_idle_secs` | `TMUX_ASK_COPY_IDLE_SECS` | `300` |
| `@tmux_agents_ask_queue_secs` | `TMUX_ASK_QUEUE_SECS` | `1800` |
| `@tmux_agents_ask_max_lines` | `TMUX_ASK_MAX_LINES` | `60` |
| `@tmux_agents_ask_enter_delay` | `TMUX_ASK_ENTER_DELAY` | `0.5` |
| `@tmux_agents_connect_highlight` | `TMUX_CONNECT_HIGHLIGHT` | `bg=colour24` |

(Defaults as the code has them today; the implementer checks each.) Internal variables (`TMUX_AGENTS_DEPTH`, `_KIND`, `_PINNED`, `_LIST_CLIENT`, `_SELECT*`, `TMUX_CONNECT_PANES`, `TMUX_ASK_IDENTITY_LOCKED`, the test hook `TMUX_SPAWN_BIN`) and internal options (`@tmux_agents_chip_pid`, `_main_format`, `_prefix_at`, `_list_mode`) aren't settings and stay as they are.

**Cost.** A script reads all `@tmux_agents_*` options with one `tmux show-options -g` call and caches them; the list build gets them inside its existing snapshot or that one call, within its process budget.

**Why tmux options.** See [given names follow the naming format](2026-10-04-names-follow-the-format.md): the user already edits `tmux.conf`, options change live, and a config file would need a parser and a reload story.
