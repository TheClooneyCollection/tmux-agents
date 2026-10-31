# CI checks

Run from the repository root with Bash 3.2 or newer:

```sh
/bin/bash ci/static.sh
python3 ci/docs.py
/bin/bash ci/suites.sh /tmp/tmux-agents-suite-logs </dev/null
/bin/bash ci/install.sh </dev/null
/bin/bash ci/upgrade.sh </dev/null
/bin/bash ci/skills-cli.sh </dev/null
```

The workflow runs runtime and installation checks on macOS and Ubuntu. It pins ShellCheck 0.11.0, fzf 0.65.2 and skills 1.7.0. Local runs need tmux, fzf, Perl, Python 3, Git and `column` (Ubuntu: `bsdextrautils`). The static check also needs ShellCheck. The upgrade check needs the local `v1.9.0` tag. Only the skills CLI check needs Node/npm and network access.

Suites use private tmux sockets and stub agents. Installation checks use temporary homes. The suite runner retains logs and runs all suites even after one fails. It disables the list's wall-clock budget on shared CI runners while retaining the process-count limits; running `tests/list-budget.sh` directly still checks its time budget.

The skills check verifies discovery, the real global installation in an isolated home, and handoff to `install.sh --force` in both symlink and copy modes. The pinned skills CLI has no mock or dry-run install; `--list` only discovers skills. `install.sh --dry-run` is separately checked for filesystem changes.

## Real Codex compatibility probe

After upgrading Codex CLI and before a release, run `ci/codex-probe.sh` locally against the installed Codex profiles and rules. By default it tests this checkout's `bin/`; pass `--installed` to test the installed commands after an upgrade. It is not a CI check because it needs real Codex authentication. The script starts one fresh `codex exec` session per selected profile inside its own tmux server, then tests plain argv, heredoc, `--message-file` where supported, and a narrowly escalated heredoc for `tmux-ask`, `tmux-spawn` and `tmux-agent-report`. It reports the exposed tool surface, the model's command result, and independently verified effects on the private server; it exits nonzero when a recommended form fails or the model's report disagrees with observed effects.

By default it probes `~/.codex` and `codex-2nd` when that profile is present in `TMUX_AGENTS_CODEX_HOMES`. Repeat `--profile NAME` to select homes explicitly, and use `--binary PATH`, `--model MODEL` or `--timeout SECONDS` to select the CLI binary, model or per-profile time bound. The header prints the selected `tmux-agents` path and this checkout's `git describe`. It uses only a private `tmux -L` socket, a fake receiver and a harmless stub child; it removes that server, its message queue and temporary files on exit. Codex itself may need network access; the probe does not install, update or contact other agents.

The session runs `codex exec`, whose originator is `codex_exec`. `tmux-spawn` launches an interactive Codex TUI, so its tool surface may differ. Treat this probe as an exec-path check; it does not claim to cover TUI-specific tool availability.
