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
