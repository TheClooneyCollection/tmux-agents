# Performance

tmux-agents does little work per action, but two things made it feel slow in real use. This page records them, with measurements, so they don't come back.

## The agent list was slow to build (fixed in v1.7.0)

**Symptom.** `prefix + a` took several seconds to open, and so did every `ctrl-t` switch between "this window" and "all windows": 4.5s and 4.9s on 28 panes and 45 session records.

**Cause.** Each list build looked things up one agent at a time: a tmux call per name, a tmux call per step when walking up an agent's parents, a `git` call per directory, plus `awk`, `basename` and `date` per row. One build launched about 850 processes on that data, and about 2,650 on a 50-pane, 100-record test fixture.

**Fix.** One `tmux list-panes -a` snapshot and one read of the session records per build; every lookup and parent walk runs in memory (awk), and each directory's project is computed once. That reduced a build to about 0.1s and 12 to 15 processes. With cached tmux-option configuration, the 50-pane/100-record fixture uses 14 processes for a list rebuild and up to 18 for opening with a selected row, including the configuration parser. `tests/list-budget.sh` fails any build over 20 external processes (counted through a PATH shim) or over a loose time cap, so per-agent lookups can't creep back in. Since v1.7.1 the picker also draws its frame before the rows are ready (`start:reload`), so the popup appears in about 50ms.

## Your shell's startup is paid on every popup and spawn

**Symptom.** Even with a fast list, `prefix + a` took 0.5 to 0.7s to open.

**Cause.** tmux runs a popup's command, and the command of every new window or split, through your `default-shell` with `-c`. That shell reads its startup files first, even though nobody will type into it. A fish config that loaded thefuck and mise and called `brew` cost 0.26 to 0.47s per `fish -c`, before tmux-agents even started. So it was paid on every `prefix + a`, every `prefix + A`, and every `tmux-spawn`. (`run-shell`, which runs the hooks, uses `/bin/sh` and isn't affected.)

**Check.**

```sh
tmux show -gv default-shell          # the shell popups use
time fish -c true                    # with your config
time fish --no-config -c true        # without it
```

For bash use `bash -c true` (and `--norc`), for zsh `zsh -c true` (and `-f`). Tens of milliseconds is fine; hundreds is what you'll feel.

**Fix pattern.** Let non-interactive shells stop once `PATH` and the environment tmux-agents needs are set, and keep everything else for interactive shells. For fish, in `config.fish`, after `PATH` and exported variables:

```fish
status is-interactive; or return
```

Tools that set themselves up before `config.fish` (fish's `conf.d`, like mise's auto-activation) need their own switch, in a `conf.d` file that sorts first, e.g. `conf.d/00-noninteractive.fish`:

```fish
status is-interactive; or set -g MISE_FISH_AUTO_ACTIVATE 0
```

With that, `fish -c true` took 0.01 to 0.02s. Interactive shells and new panes load everything as before.

**Trade-offs.** Commands run with `fish -c` no longer see what the skipped parts set up: mise-managed tools, aliases and functions from the rest of the config. If a non-interactive command needs a mise tool, put mise's shims on PATH instead of activating it (`fish_add_path --append ~/.local/share/mise/shims`), or call the tool by full path. Prefer computing paths once over running a program to find them (Homebrew's unversioned `/opt/homebrew/opt/<formula>` links instead of `brew --prefix <formula>`).

## Shell popup startup (command mode)

Shell startup now combines opener metadata into one read and pane option changes into one tmux invocation. Popup dispatch precedes deferred label refresh. `tests/shell-runtime-perf.sh` compares the implementation with commit `4ca5879` on a private socket using a marker shell and intercepted popup dispatch, including the child startup gate in call counts.

Five samples per version gave these medians on the development machine:

| Measurement | Before | After |
| --- | --- | --- |
| tmux calls before shell starts | 30 | 11 |
| tmux calls before popup dispatch | 41 | 11 |
| Shell startup, without instrumentation | 290.2ms | 138.0ms |
| Popup dispatch, without instrumentation | 395.9ms | 132.4ms |

These measure dispatch, not the time a popup finishes drawing. User interactive shell configuration is outside this measurement. The earlier estimate of 46 calls was not reproduced by this harness.

Command records share the existing batched record read. The list budget suite passed all 52 checks: 14 tools per rebuild, 22.5ms to fzf and 195.0ms to first rows; opening with a selected row took 27.0ms and 213.1ms respectively. These local timings are observations, not portable guarantees.

## Where to look next time

The `tmux-agents-perf` skill walks an agent through measuring each part of the path: the shell's startup, the list build against the budget, fzf and the popup, and process counts per command.
