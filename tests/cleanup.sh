#!/usr/bin/env bash
# EXIT cleanup reaps direct jobs and server workers before deleting their queue.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-agents-cleanup-test-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-cleanup-test.XXXXXX")"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE
# Start explicitly with /bin/sh; never load the user's shell configuration.
tmux -L "$sock" -f /dev/null new-session -d -s work /bin/sh
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket' >&2; exit 1 ;; esac
export TMUX="$S,1,0"
cat > "$tmp/tmux-ask" <<'WORKER'
#!/bin/bash
queue="${2%/*}"
marker="$3"
trap 'mkdir -p "$queue"; touch "$queue/recreated" "$marker.stopped"; exit 0' TERM
: > "$marker.ready"
while :; do sleep .05; done
WORKER
chmod +x "$tmp/tmux-ask"
# One suite-owned background job and one server-owned delivery worker.
"$tmp/tmux-ask" --kick "$queue/message" "$tmp/direct" </dev/null &
tmux -L "$sock" run-shell -b "exec '$tmp/tmux-ask' --deliver '$queue/message' '$tmp/server' </dev/null"
for attempt in {1..100}; do
  [ ! -f "$tmp/direct.ready" ] || [ ! -f "$tmp/server.ready" ] || break
  sleep .05
done
[ -f "$tmp/direct.ready" ] && [ -f "$tmp/server.ready" ]
cleanup_test_server
[ -f "$tmp/direct.stopped" ] && [ -f "$tmp/server.stopped" ]
[ ! -e "$queue" ]
if tmux -L "$sock" has-session 2>/dev/null; then
  echo "FAIL: cleanup left the private test server running" >&2
  exit 1
fi
# Unsafe socket names must fail before deleting anything or touching a server.
saved_sock="$sock"
for sock in '' . .. default ../default; do
  if cleanup_test_server 2>"$tmp/rejected"; then
    echo "FAIL: accepted unsafe socket '$sock'" >&2
    exit 1
  fi
done
sock="$saved_sock"
echo 'Passed cleanup checks: direct jobs, delivery workers, queue removal, socket guard'
