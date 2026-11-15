#!/usr/bin/env bash
# Layout activation warns about broken skills in current/configured agent homes.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-skill-links-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-skill-links.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT TMUX_AGENTS_CODEX_HOMES
export HOME="$tmp/home" CODEX_HOME="$tmp/current" XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills" "$CODEX_HOME/skills" "$tmp/healthy"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# Disable the daemon; this suite tests activation, not background animation.
tmux -L "$sock" set -g @tmux_agents_chip_fps 1
tmux -L "$sock" set-environment -gu TMUX_AGENTS_CODEX_HOMES
count=0 failures=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; failures=$((failures+1)); fi; }
contains() { grep -Fq -- "$2" "$1"; }
absent() { ! contains "$@"; }
run() { "$B/tmux-agents" "$@" >"$tmp/out" 2>"$tmp/err" </dev/null; }
run --chip-layout on
check 'missing skills are quiet' test ! -s "$tmp/err"
ln -s "$tmp/healthy" "$HOME/.claude/skills/tmux-agents"
ln -s "$tmp/healthy" "$CODEX_HOME/skills/agent-chain"
mkdir "$CODEX_HOME/skills/tmux-agents-setup"
ln -s "$tmp/missing" "$CODEX_HOME/skills/unrelated"
run --chip-layout on
check 'healthy links, directories and unrelated links are quiet' test ! -s "$tmp/err"
ln -s "$tmp/missing" "$HOME/.claude/skills/tmux-agents-perf"
ln -s "$tmp/missing" "$CODEX_HOME/skills/tmux-agents-custom"
rm "$CODEX_HOME/skills/agent-chain"
ln -s "$tmp/missing" "$CODEX_HOME/skills/agent-chain"
ln -s "$tmp/missing" "$HOME/.codex/skills/agent-chain"
run --chip-layout on
check 'Claude broken link warns' contains "$tmp/err" "$HOME/.claude/skills/tmux-agents-perf"
check 'current Codex home warns for wildcard skill' contains "$tmp/err" "$CODEX_HOME/skills/tmux-agents-custom"
check 'agent-chain broken link warns' contains "$tmp/err" "$CODEX_HOME/skills/agent-chain"
check 'warning explains installation checkout repair' contains "$tmp/err" 'rerun install.sh from the installation checkout'
check 'default Codex home is scanned alongside current home' contains "$tmp/err" "$HOME/.codex/skills/agent-chain"
check 'warnings stay off stdout' absent "$tmp/out" 'broken skill symlink'
for args in '--chip-layout off' '--list' '--chip'; do
  run $args
  check "$args does not scan broken skills" test ! -s "$tmp/err"
done
saved_codex_home="$CODEX_HOME"
unset CODEX_HOME
run --chip-layout on
check 'unset CODEX_HOME scans default' contains "$tmp/err" "$HOME/.codex/skills/agent-chain"
export CODEX_HOME=''
run --chip-layout on
check 'empty CODEX_HOME scans default' contains "$tmp/err" "$HOME/.codex/skills/agent-chain"
export CODEX_HOME="$saved_codex_home"
for profile in env option global; do
  mkdir -p "$tmp/$profile/skills"
  ln -s "$tmp/missing" "$tmp/$profile/skills/agent-chain"
done
tmux -L "$sock" set-environment -g TMUX_AGENTS_CODEX_HOMES "global=$tmp/global"
run --chip-layout on
check 'tmux global environment homes scanned' contains "$tmp/err" "$tmp/global/skills/agent-chain"
tmux -L "$sock" set -g @tmux_agents_codex_homes "option=$tmp/option"
run --chip-layout on
check 'option homes scanned' contains "$tmp/err" "$tmp/option/skills/agent-chain"
check 'option beats tmux global environment' absent "$tmp/err" "$tmp/global/skills/agent-chain"
export TMUX_AGENTS_CODEX_HOMES="env=$tmp/env duplicate=$tmp/env current=$CODEX_HOME"
run --chip-layout on
check 'environment homes scanned' contains "$tmp/err" "$tmp/env/skills/agent-chain"
check 'environment beats option' absent "$tmp/err" "$tmp/option/skills/agent-chain"
check 'environment beats global environment' absent "$tmp/err" "$tmp/global/skills/agent-chain"
check 'duplicate configured homes warn once' test "$(grep -Fc "$tmp/env/skills/agent-chain" "$tmp/err")" = 1
check 'current home duplicated in map warns once' test "$(grep -Fc "$CODEX_HOME/skills/agent-chain" "$tmp/err")" = 1
export TMUX_AGENTS_CODEX_HOMES=''
run --chip-layout on
check 'empty environment falls back to option' contains "$tmp/err" "$tmp/option/skills/agent-chain"
tmux -L "$sock" set -gu @tmux_agents_codex_homes
run --chip-layout on
check 'unset option falls back to global environment' contains "$tmp/err" "$tmp/global/skills/agent-chain"
printf '\n%s checks, %s failures\n' "$count" "$failures"
[ "$failures" -eq 0 ]
