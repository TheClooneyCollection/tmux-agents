#!/usr/bin/env bash
# Run every offline regression suite, preserving logs and all failure statuses.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 1 ]; then echo 'usage: ci/suites.sh [LOGS_DIR]' >&2; exit 2; fi
logs="${1:-${TMUX_CI_LOGS_DIR:-$here/ci-logs/suites}}"
mkdir -p "$logs"
logs="$(cd "$logs" && pwd)"
unset TMUX TMUX_PANE
# Hosted runners vary in speed. Structural process/snapshot budgets stay strict.
export TMUX_LIST_BUDGET_SKIP_TIME=1
passed=0
failed=0
: >"$logs/summary.txt"
for suite in "$here"/tests/*.sh; do
  name="${suite##*/}"
  printf 'RUN  %s\n' "$name"
  if /bin/bash "$suite" </dev/null >"$logs/$name.log" 2>&1; then
    passed=$((passed + 1))
    printf 'PASS %s\n' "$name" | tee -a "$logs/summary.txt"
  else
    status=$?
    failed=$((failed + 1))
    printf 'FAIL %s (exit %s)\n' "$name" "$status" | tee -a "$logs/summary.txt"
    cat "$logs/$name.log"
  fi
done
printf '%s passed; %s failed. Logs: %s\n' "$passed" "$failed" "$logs" | tee -a "$logs/summary.txt"
[ "$failed" -eq 0 ]
