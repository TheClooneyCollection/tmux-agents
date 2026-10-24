# Configuration

Set user preferences in `tmux.conf`, or change them live with `tmux set -g`. Environment overrides win over options, then the defaults below apply. For given names, `--exact` takes priority over both. Use the full name printed by `tmux-agents start`, `tmux-spawn` or `tmux-rename`. The list and preview settings apply to the `prefix + a` agent list, which needs `fzf`.

```tmux
set -g @tmux_agents_name_format exact
```

| Option | Environment override | Default | What it does |
| --- | --- | --- | --- |
| `@tmux_agents_shell_key` | `TMUX_AGENTS_SHELL_KEY` | `S` | Plain shell popup key; `none` disables. Set before sourcing, then re-source. |
| `@tmux_agents_command_key` | `TMUX_AGENTS_COMMAND_KEY` | `C-s` | History command picker key; `none` disables. Set before sourcing, then re-source. |
| `@tmux_agents_shell_close_secs` | `TMUX_AGENTS_SHELL_CLOSE_SECS` | `3` | Successful command countdown in whole seconds; `0` closes immediately. Any key keeps the pane open. |
| `@tmux_agents_name_format` | `TMUX_AGENTS_NAME_FORMAT` | `prefixed` | Given-name format: `exact` or `prefixed` |
| `@tmux_agents_sub_auto` | `TMUX_AGENTS_SUB_AUTO` | `on` | Spawned and resumed Claude/Codex agents, including members: `on` adds auto permission flags; `off` uses agent defaults. Does not affect `start`. |
| `@tmux_agents_chain_main` | `TMUX_AGENTS_CHAIN_MAIN` | `claude` | Main agent for a new `start chain` window |
| `@tmux_agents_chain_secondary` | `TMUX_AGENTS_CHAIN_SECONDARY` | `claude` | Secondary for a new chain |
| `@tmux_agents_chain_worker` | `TMUX_AGENTS_CHAIN_WORKER` | `codex` | Worker for a new chain |
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
| `@tmux_agents_reply_overdue_secs` | `TMUX_AGENTS_REPLY_OVERDUE_SECS` | `1800` | Inactive seconds after delivery before showing reply overdue; `0` disables |
| `@tmux_agents_ask_max_lines` | `TMUX_ASK_MAX_LINES` | `60` | Save longer messages to a file |
| `@tmux_agents_ask_enter_delay` | `TMUX_ASK_ENTER_DELAY` | `0.5` | Seconds between paste and Enter |
| `@tmux_agents_connect_highlight` | `TMUX_CONNECT_HIGHLIGHT` | `bg=colour24` | Style of the highlighted connection target |

`TMUX_AGENTS_CODEX_HOMES` also keeps its tmux global-environment fallback when neither a local override nor the option is set. Settings are read once per command; restart an existing picker or chip daemon to apply changes to its cached settings. Set overrides after sourcing `tmux-agents.conf`, which installs the chip FPS default, except for `@tmux_agents_shell_key` and `@tmux_agents_command_key`: set them before sourcing, because their bindings are installed at source time. Internal pane state and test hooks are not user settings.

`resume_days` controls closed-agent list retention. Request records have a separate fixed seven-day retention after answering or cancellation; pending requests and records referenced by queued messages do not expire by age. See [request completion](design/state-and-protocol.md#request-completion) for cleanup triggers and notification deduplication.

With `sub_auto` on, `tmux-spawn` adds Claude's `--permission-mode auto` or Codex's `-c approvals_reviewer="auto_review"`. With it off, neither flag is added. The setting applies to new and resumed Claude/Codex agents, including members. Other executables keep their own permission behavior; no permission flags or rules are added.

`tmux-agents start PROFILE` uses the same Codex-home lookup and given-name preferences as `tmux-spawn`. The launcher runs in the current pane and supplies per-process identity pins and turn hooks without editing global agent config. It keeps the agent's permission defaults; pass agent-specific options after `--`. Shell wrappers are optional and provide identity pins only. See [Starting agents](guide.md#starting-agents).

## Reply overdue

A delivered, unanswered request shows `reply overdue` on its receiver after 1800 seconds without observable progress. Set `@tmux_agents_reply_overdue_secs` or `TMUX_AGENTS_REPLY_OVERDUE_SECS` to a nonnegative number of seconds; `0` disables it. Reported progress and turn events restart the inactivity interval; it does not inspect the agent TUI or infer arbitrary background-task completion. This is separate from queued `message waiting`, does not change the agent's state to `needs_you`, and does not measure the task's total duration. Inspect the receiver's progress before deciding whether to intervene.

## Shell popup key

`prefix + C-s` opens the history command picker; `prefix + S` opens a plain shell. Configure both keys before sourcing the tmux configuration. The existing shell setting keeps its meaning but its default changes from `C-s` to `S`:

```tmux
set -g @tmux_agents_shell_key S
set -g @tmux_agents_command_key C-s
set -g @tmux_agents_shell_close_secs 3
source-file ~/path/to/tmux-agents/tmux/tmux-agents.conf
```

Nonempty `TMUX_AGENTS_SHELL_KEY` and `TMUX_AGENTS_COMMAND_KEY` override their options. Use `none` to disable either shortcut; empty values fall through to the next source. The two enabled keys must differ. To keep a custom plain-shell binding on `C-s`, move the command binding to another key or set it to `none`.

Re-source after changing a shortcut. `tmux-agents --shell-binding` validates both keys before applying them, remembers the installed bindings, and removes a previous key only if it still holds this tool's binding. Swapping the two shortcuts is supported; user replacements are preserved. The lowercase `prefix + s` session picker is unchanged. Disabling a shortcut leaves the CLI available.

`@tmux_agents_shell_close_secs` is a nonnegative integer, overridden by nonempty `TMUX_AGENTS_SHELL_CLOSE_SECS`. It controls successful commands only, defaults to three seconds, and is read for each launch. `0` closes immediately. Any key during a positive countdown keeps the pane open as an interactive shell. Failed commands always leave an interactive shell. See [Shell panes](guide.md#shell-panes) for history, results and ownership.

## Codex profiles

First create and sign in to each Codex home using Codex's own setup. Map profile names to those existing directories. From a tmux shell:

```sh
tmux set -g @tmux_agents_codex_homes "work=$HOME/.codex-work"
```

To persist the setting, add this to `~/.tmux.conf`:

```tmux
set -g @tmux_agents_codex_homes "work=$HOME/.codex-work"
```

Use space-separated `name=path` pairs for several profiles. An environment override takes priority over the option:

```sh
export TMUX_AGENTS_CODEX_HOMES="work=$HOME/.codex-work"
```

The legacy `set-environment -g TMUX_AGENTS_CODEX_HOMES ...` fallback applies only when neither a local override nor the option is set. It does not override an environment value already inherited by a running agent.

Rerun `./install.sh` from your installation checkout so each configured home gets the skills and Codex rules. Then use `tmux-agents start work` for a top-level agent, or `tmux-spawn work --from ME "task"` for a helper (`ME` is its parent's full name). Launched agents receive the resolved profile map as a process-local environment snapshot for subsequent helpers and queries; restart them to pick up changes to the mapping option. Helpers inherit their parent's profile unless given another kind explicitly. The profile remains `work` for account selection, but generated names use the `codex` prefix.

## Chain roles

Each role accepts `claude`, `codex`, an exact configured Codex profile name or an executable basename on PATH. Profiles win over same-named executables and retain their account selection; generated profile names use the `codex` prefix. The same selection rules apply to `start`, `tmux-spawn` and `chain-config`. Other executables have [limited support](agents.md): no initial task is sent, including the chain request for an unknown main. Send the actual brief manually with `tmux-ask` once the agent is at its prompt. Main and secondary roles require particular supervision because other agents have no agent-chain skill integration.

```tmux
set -g @tmux_agents_chain_main codex
set -g @tmux_agents_chain_secondary claude
set -g @tmux_agents_chain_worker work
```

Configure the `work` profile first as above. Settings apply to new chains, not existing members or resumed agents. From a shell, override any role for this chain:

```sh
tmux-agents start chain . --main codex --secondary claude --worker work
```

The order of preference is this-chain explicit user choice or CLI flag, then an applicable user's `CLAUDE.md`/`AGENTS.md` role preference, then a non-empty environment override, then a non-empty tmux option, then the built-in default. The skill passes instruction-file preferences as explicit overrides; the CLI does not read Markdown. Conflicting instruction files follow the agent's normal instruction hierarchy.

Window placement and naming are per-launch options: `--target session[:index]` creates a detached window in an existing session, and `--name NAME` overrides the directory-derived window name. These options can appear in any order with DIR and the role flags; they do not change role selection or validation. See [Starting agents](guide.md#starting-agents) for socket selection, output and examples.

The main setting only selects the agent launched by `tmux-agents start chain`. The shell cannot apply instruction files that the main has not read yet, so configure that initial main with an option, environment override or `--main`. Saying “start the chain” to an existing top-level agent keeps that agent as main. To use a different main, launch a new chain window.

### Inspecting the choices

```sh
tmux-agents chain-config [main|secondary|worker] [--main AGENT] [--secondary AGENT] [--worker AGENT] [--sources]
```

This read-only query needs no `--from` and creates no window, pane or agent record. With no role argument, it prints TSV rows in `main`, `secondary`, `worker` order, with role and value columns. `--sources` adds `explicit`, `env`, `option` or `default` as a third column. A selected role without `--sources` prints only its value; with `--sources` it prints the full three-column row. Explicit flags validate hypothetical choices without changing settings. File preferences passed by the skill appear as `explicit`.

The output shows the settings new chains start from, not the members of a running chain: a chain launched with `--secondary codex`, or whose worker came from an instruction-file preference, still reports the plain settings afterwards. Use `tmux-peers` to see the live members.

```sh
tmux-agents chain-config --sources
tmux-agents chain-config worker
tmux-agents chain-config worker --worker work --sources
```

A selected-role query validates that role only; an all-role query and `start chain` validate all three. Invalid choices fail with no partial stdout; launch validation happens before creating a window. Empty explicit values and repeated flags are errors. Empty environment overrides and options fall through to the next source. Outside tmux (`TMUX` unset), queries use environment values and defaults without consulting the default server; options are unavailable. If `TMUX` is set but its socket cannot be reached, the query fails rather than presenting defaults as resolved settings. Role settings have no tmux global-environment fallback.

### Migrating an instruction-file preference

An existing instruction such as “My worker runs on the second Codex account: `codex-2nd`” still wins over the worker option. To make settings the lasting source of that preference, configure the profile mapping, set the option, then remove that instruction or replace it with “Use the chain-config role settings”:

```tmux
set -g @tmux_agents_codex_homes "codex-2nd=$HOME/.codex-2nd"
set -g @tmux_agents_chain_worker codex-2nd
```

Rerun `./install.sh` from your installation checkout after adding a profile so its home receives the skills and rules. Merely setting `CODEX_HOME` does not install them.

The main keeps its agent permission defaults. Claude/Codex secondary and worker members use `sub_auto`, which defaults to `on`. Codex main uses identity pins and notify tracking, but has no turn-start hook: the main uses `--local` at the start of each direct user task and `--local-done` when that local work finishes. See [Starting agents](guide.md#starting-agents).
