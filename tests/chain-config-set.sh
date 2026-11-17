#!/usr/bin/env bash
# Live role settings validate first and print reusable tmux.conf lines.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-chain-set-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-chain-set.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE TMUX_AGENTS_CHAIN_WORKER TMUX_AGENTS_CHAIN_SECONDARY
export XDG_STATE_HOME="$tmp/state"
tmux -L "$sock" -f /dev/null new-session -d -s work /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
run() { "$here/bin/tmux-agents" chain-config "$@"; }
run set worker codex -- --model custom > "$tmp/out"
[ "$(run worker --args)" = $'worker\tcodex\t--model custom' ]
grep -qx "set -g @tmux_agents_chain_worker 'codex'" "$tmp/out"
grep -qx "set -g @tmux_agents_chain_worker_args '--model custom'" "$tmp/out"
run set secondary claude > "$tmp/out"
[ "$(run interface --args)" = $'interface\tclaude\t-' ]
run set researcher claude -- --model "single'quote" > "$tmp/conf"
tmux source-file "$tmp/conf"
[ "$(run researcher --args)" = $'researcher\tclaude\t--model single\'quote' ]
for role in main designer interface worker reviewer runner researcher; do
  run set "$role" codex > /dev/null
  [ "$(run "$role")" = codex ]
done
before="$(run --args --sources)"
for role in unknown worker; do
  if run set "$role" missing-executable > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
done
if run set worker codex -- $'bad\nargs' > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run set worker codex --model bad > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
for arg in 'two words' $'two\twords' $'two\nwords' ''; do
  if run set worker codex -- --model "$arg" > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
  grep -q 'space-separated without quoting' "$tmp/err"
done
[ "$(run --args --sources)" = "$before" ]
echo 'ok live role set, aliases, literal output, cleared args and validation'
