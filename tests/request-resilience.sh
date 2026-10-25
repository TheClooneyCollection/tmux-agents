#!/usr/bin/env bash
# Ledger failures and gone receivers must never wedge delivery or completion.
# Drives the real scripts in an isolated tmux server with `cat` panes.
#
#   tests/request-resilience.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-resilience-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"

unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0

tmux -L "$sock" -f /dev/null new-session -d -x 120 -y 30 cat
tmux -L "$sock" has-session 2>/dev/null || { echo "ABORT: test server not up"; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { chmod -R u+w "$state_dir" 2>/dev/null; cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT

tmux set-option -g default-shell /bin/sh
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"
ledger="$state_dir/tmux-agents/$sock/requests"

fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
st() { tmux show -pqv -t "$1" "$2"; }
new_agent() { local p; p="$(tmux new-window -d -P -F '#{pane_id}' cat)"; tmux set -p -t "$p" @agent "$1"; tmux set -p -t "$p" @tracked 1; tmux set -p -t "$p" @state working; ensure_agent_id "$p" >/dev/null; printf '%s\n' "$p"; }
turn_end() { "$B/tmux-agent-report" --pane "$1" --turn-end </dev/null; }
pending() { grep -lx 'status=pending' "$ledger"/r*.record 2>/dev/null | wc -l | tr -d ' '; }

tmux set -p -t %0 @agent main; tmux set -p -t %0 @tracked 1; tmux set -p -t %0 @state working
helper="$(new_agent helper)"

echo "A receiver that is gone no longer blocks its requester"
TMUX_PANE=%0 "$B/tmux-ask" --any helper 'look into this' >/dev/null
check 'request recorded as pending' test "$(pending)" = 1
turn_end %0
check 'requester waits for a live receiver' test "$(st %0 @state)" = working
check 'requester shows the awaited name' test "$(st %0 @activity)" = 'waiting for helper'
tmux kill-pane -t "$helper"
turn_end %0
check 'requester goes idle once the receiver is gone' test "$(st %0 @state)" = idle
check 'gone receiver drops out of @awaiting' test -z "$(st %0 @awaiting)"
check 'the request itself keeps its identity for a reopen' test "$(pending)" = 1

echo "A tab in a wait reason cannot shift ledger columns"
peer="$(new_agent peer)"
"$B/tmux-agent-report" --pane "$peer" --waiting "$(printf 'lint\tbuild')" >/dev/null
check 'tab is flattened in the pane option' test "$(st "$peer" @waiting_on)" = 'lint build'
turn_end "$peer"
check 'the wait reason reaches the activity intact' test "$(st "$peer" @activity)" = 'waiting for lint build'
check 'a top-level wait is not a needs-you' test "$(st "$peer" @state)" = working
TMUX_PANE=%0 "$B/tmux-ask" --any peer 'while you wait' >/dev/null
check 'a request to a waiting pane is pending' test "$(pending)" = 2
check 'tab-free columns keep the shell flag correct' test "$(st "$peer" @request_pending_since)" != ''

echo "A rejected request publication leaves no orphan queue files"
chmod 500 "$ledger"
if TMUX_PANE=%0 "$B/tmux-ask" --any peer 'ledger is down' >/dev/null 2>&1; then echo 'FAIL  request accepted without a ledger'; fail=1; else echo 'ok    request refused without a ledger'; fi
chmod 700 "$ledger"
check 'no stray .meta after a refused request' test "$(find "$queue" -name '*.meta' 2>/dev/null | wc -l | tr -d ' ')" = 0
check 'no stray .tmp after a refused request' test "$(find "$queue" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')" = 0

[ "$fail" -eq 0 ] && echo "all passed" || echo "some failed"
exit "$fail"
