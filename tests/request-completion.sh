#!/usr/bin/env bash
# Regression tests for "needs you": normal workflows must not flag a sub
# agent as needing the user, and a few real cases must. Drives the real
# scripts in an isolated tmux server (never the user's), with `cat` panes
# standing in for agents and Claude hooks / Codex notify simulated by
# calling tmux-agent-report directly.
#
#   tests/needs-you.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-requests-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"

unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0

tmux -L "$sock" -f /dev/null new-session -d -x 120 -y 30 cat
# Never let this reach the user's live server: the test server must be up,
# on a real socket that isn't the default one.
tmux -L "$sock" has-session 2>/dev/null || { echo "ABORT: test server not up"; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT

tmux set-option -g default-shell /bin/sh
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"

# boss (%0) and its sub agent kid (%1), connected like tmux-spawn does.
tmux split-window cat
TMUX_PANE=%0 "$B/tmux-connect" %1 --as boss <<< kid >/dev/null
tmux set -p -t %1 @parent %0

fail=0
st() { tmux show -pqv -t "$1" "$2"; }
reset() {
  for p in %0 %1; do
    for o in @attention_since @waiting_on @awaiting @activity @codex_thread; do tmux set -pu -t "$p" "$o" 2>/dev/null; done
  done
  tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state working
}
turn_end() { "$B/tmux-agent-report" --pane %1 --turn-end </dev/null; }
ask() { local from="$1"; shift; TMUX_PANE="$from" "$B/tmux-ask" "$@" >/dev/null; }
expect() {  # name, wanted kid state
  local got
  got="$(st %1 @state)"
  if [ "$got" = "$2" ]; then echo "ok    $1 ($got)"; else echo "FAIL  $1: kid is $got, wanted $2"; fail=1; fi
}

check() {
  local label="$1"; shift
  if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi
}


tmux new-window -d cat
other="$(tmux list-panes -a -F '#{pane_id}' | tail -1)"
tmux set -p -t "$other" @agent investigator
request_dir="$(dirname "$(sessions_dir)")/requests"
latest() { local f; for f in "$request_dir"/r*.record; do [ -f "$f" ] || continue; if grep -qx "status=pending" "$f"; then basename "$f" .record; fi; done; }
reset
agent_set_state %1 "done"
TMUX_PANE="$other" "$B/tmux-ask" --any kid 'peer task one' >/dev/null
first="$(latest)"
check 'request has unique identity' test -n "$first"
ask %1 --any --reply investigator 'answer one'
turn_end
expect 'completed peer request restores done' "done"
reset
agent_set_state %1 idle
TMUX_PANE="$other" "$B/tmux-ask" --any kid 'idle peer task' >/dev/null
ask %1 --any --reply investigator 'idle answer'
turn_end
expect 'completed peer request restores idle' idle
reset
agent_set_state %1 "done"
TMUX_PANE="$other" "$B/tmux-ask" --any kid 'overlap first' >/dev/null
first="$(latest)"
TMUX_PANE="$other" "$B/tmux-ask" --any kid 'overlap second' >/dev/null
second="$(latest | grep -v "^$first$")"
if ask %1 --any --reply investigator 'ambiguous'; then echo 'FAIL ambiguous pair reply accepted'; fail=1; else echo 'ok ambiguous pair reply refused'; fi
ask %1 --any --reply investigator --request-id "$first" 'first complete'
turn_end
expect 'remaining same-pair request needs answer' needs_you
check 'requester still awaits same receiver' test -n "$(st "$other" @awaiting)"
ask %1 --any --reply investigator --request-id "$second" 'second complete'
turn_end
expect 'all same-pair requests complete' "done"
check 'last reply clears requester wait' test -z "$(st "$other" @awaiting)"
exit "$fail"
