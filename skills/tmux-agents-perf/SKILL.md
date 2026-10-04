---
name: tmux-agents-perf
description: Find where a tmux-agents delay comes from and how to fix it. Use when the user says prefix + a, prefix + A, the agent list, tmux-spawn, tmux-ask or tmux-agents in general feels slow or laggy.
---

# Finding a tmux-agents delay

Measure first, then explain. Work read-only on the user's live tmux server: time commands and read options, but don't change options, kill anything, or reload config there. Anything that needs a test server runs on `tmux -L <testname>`, after checking `tmux -L <testname> has-session` succeeds and its socket path isn't `*/default`.

## 1. The shell that popups and spawns use

tmux runs every popup's command and every new window's or split's command through `default-shell -c`, so its startup is paid each time (`run-shell` and hooks use `/bin/sh` and aren't affected).

    tmux show -gv default-shell
    time <shell> -c true                 # three times; the first can be cold
    time <shell> --no-config -c true     # fish; bash: --norc, zsh: -f

If the first is much slower than the second, the config is the cost. Find which part:
- fish: `fish --profile-startup /tmp/fish-prof.txt -c true`, then `sort -k2 -n -r /tmp/fish-prof.txt | head`.
- bash 5+: `PS4='+ $EPOCHREALTIME ' bash -x -ic exit 2>&1 | head -200`; zsh: `PS4='+%D{%s.%.} ' zsh -xic exit 2>&1 | head -200`. Each traced line starts with a timestamp, so big jumps point at the slow part. Or time sections by commenting them out in a copy of the config.

## 2. The list build

    C=$(tmux list-clients -F '#{client_name}' | head -1)
    time env TMUX_AGENTS_LIST_CLIENT="$C" FZF_PROMPT="agents · this window> " tmux-agents --list >/dev/null
    time env TMUX_AGENTS_LIST_CLIENT="$C" FZF_PROMPT="agents · all windows> " tmux-agents --list >/dev/null

About 0.1s is expected. Note the size of the data (`tmux list-panes -a | wc -l`, and the number of files in `~/.local/state/tmux-agents/<socket>/sessions/`). If it's slow, count what it launches: run it under `bash -x` and count commands (`grep -oE '^\++ ?[a-z]+' | sort | uniq -c | sort -rn`), or wrap commands with a PATH shim that logs each call. More than about 20 external processes is a regression: `tests/list-budget.sh` (run in the tmux-agents checkout) should fail on it; say which function is doing per-agent lookups.

## 3. The picker and popup

Time from `tmux-agents --client "$C"` to fzf starting with a stub `fzf` first on PATH that records the time and exits (about 50ms is expected; the rows load after fzf starts). The preview is one `tmux capture-pane`, normally a few milliseconds.

## 4. Other commands

`time tmux-ask ...`, `time tmux-spawn ...` (on a test server), `time tmux-peers`. tmux-spawn also pays the shell startup from step 1 for the new window.

## Report

Give the user a short table: each step, its time, and what dominates, with the commands you ran so they can repeat them. Then the fix that fits, with its trade-off:
- **Shell config doing interactive work for `-c` shells:** stop non-interactive shells after PATH and exported variables (fish: `status is-interactive; or return` in `config.fish`; bash: `[[ $- == *i* ]] || return` in `.bashrc`; zsh: put interactive setup in `.zshrc`, not `.zshenv`). Trade-off: `-c` commands lose aliases, functions and tools set up later in the config.
- **Version managers that activate themselves (mise, asdf, rbenv init):** disable auto-activation for non-interactive shells (fish + mise: `set -g MISE_FISH_AUTO_ACTIVATE 0` in a `conf.d` file that sorts first); if `-c` commands need the tools, put the shims on PATH instead (`fish_add_path --append ~/.local/share/mise/shims`).
- **Programs run just to compute a path** (`brew --prefix x`): use the fixed path.
- **A slow list build:** a tmux-agents bug; report it with the numbers and the process counts (see `docs/performance.md`).

Don't edit the user's shell config or tmux options without asking; show the change and its trade-off first.
