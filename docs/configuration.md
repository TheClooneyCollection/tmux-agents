# Configuration

Set user preferences in `tmux.conf`, or change them live with `tmux set -g`. Environment overrides win over options, then the defaults below apply. For given names, `--exact` takes priority over both. Use the full name printed by `tmux-spawn` or `tmux-rename`. The list and preview settings apply to the `prefix + a` agent list, which needs `fzf`.

```tmux
set -g @tmux_agents_name_format exact
```

| Option | Environment override | Default | What it does |
| --- | --- | --- | --- |
| `@tmux_agents_name_format` | `TMUX_AGENTS_NAME_FORMAT` | `prefixed` | Given-name format: `exact` or `prefixed` |
| `@tmux_agents_max_depth` | `TMUX_AGENTS_MAX_DEPTH` | `2` | Maximum sub agent depth |
| `@tmux_agents_codex_homes` | `TMUX_AGENTS_CODEX_HOMES` | `none` | Extra accounts as `PROFILE=CODEX_HOME` pairs |
| `@tmux_agents_session_prefix` | `TMUX_AGENTS_PREFIX` | `agents` | Hidden session name prefix |
| `@tmux_agents_resume_days` | `TMUX_AGENTS_RESUME_DAYS` | `7` | Days to retain closed agents in the list |
| `@tmux_agents_preview_secs` | `TMUX_AGENTS_PREVIEW_SECS` | `0.5` | Seconds between preview refreshes while following |
| `@tmux_agents_blink_secs` | `TMUX_AGENTS_BLINK_SECS` | `60` | Seconds before attention starts blinking |
| `@tmux_agents_chip_fps` | none | `10` | Chip animation frames per second |
| `@tmux_agents_ask_idle_secs` | `TMUX_ASK_IDLE_SECS` | `8` | Seconds without keys before delivery |
| `@tmux_agents_ask_copy_idle_secs` | `TMUX_ASK_COPY_IDLE_SECS` | `300` | Exit idle copy mode after this many seconds; `0` disables |
| `@tmux_agents_ask_queue_secs` | `TMUX_ASK_QUEUE_SECS` | `1800` | Seconds before showing message waiting; messages stay queued |
| `@tmux_agents_ask_max_lines` | `TMUX_ASK_MAX_LINES` | `60` | Save longer messages to a file |
| `@tmux_agents_ask_enter_delay` | `TMUX_ASK_ENTER_DELAY` | `0.5` | Seconds between paste and Enter |
| `@tmux_agents_connect_highlight` | `TMUX_CONNECT_HIGHLIGHT` | `bg=colour24` | Style of the highlighted connection target |

`TMUX_AGENTS_CODEX_HOMES` also keeps its tmux global-environment fallback when neither a local override nor the option is set. Settings are read once per command; restart an existing picker or chip daemon to apply changes to its cached settings. Set overrides after sourcing `tmux-agents.conf`, which installs the chip FPS default. Internal pane state and test hooks are not user settings.

