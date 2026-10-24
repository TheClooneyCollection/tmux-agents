#!/usr/bin/env bash
# Receiver inactivity badges, independent state, visibility and chip focus.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-reply-overdue-ui-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-reply-overdue-ui.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT TMUX_AGENTS_REPLY_OVERDUE_SECS
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
# Freeze UI time to test the exact threshold without scheduler races.
mkdir "$tmp/tools"
real_date="$(command -v date)"
cat >"$tmp/tools/date" <<EOF_DATE
#!/bin/sh
if [ "\$*" = +%s ]; then echo 2000000000; else exec '$real_date' "\$@"; fi
EOF_DATE
chmod +x "$tmp/tools/date"
export PATH="$tmp/tools:$PATH"
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=$((fail+1)); fi; }
# shellcheck disable=SC2329
contains() { grep -Fq -- "$2" "$1"; }
# shellcheck disable=SC2329
absent() { ! contains "$@"; }
list() { FZF_PROMPT="${1:-agents · this window> }" "$B/tmux-agents" --list | tr '\0' '\n' >"$tmp/list"; }
chip() { CHIP_SPIN=SPIN "$B/tmux-agents" --chip >"$tmp/chip"; }
tmux set -p -t %0 @agent main
receiver="$(tmux new-window -d -t work -c "$tmp" -P -F '#{pane_id}' cat)"
tmux set -p -t "$receiver" @agent receiver
tmux set -p -t "$receiver" @tracked 1
tmux set -p -t "$receiver" @state working
tmux set -p -t "$receiver" @request_pending_since 1999998201
list 'all · all windows> '
check 'before default threshold' absent "$tmp/list" 'reply overdue'
tmux set -p -t "$receiver" @request_pending_since 1999998200
for prompt in 'agents · this window> ' 'agents · all windows> ' 'all · this window> ' 'all · all windows> '; do
  list "$prompt"
  check "$prompt exact threshold pins receiver" contains "$tmp/list" 'reply overdue'
  check "$prompt preserves working state" contains "$tmp/list" '⠿ working'
  check "$prompt distinct from needs you" absent "$tmp/list" 'needs you'
done
chip
check 'sole top-level overdue keeps chip visible and focused' contains "$tmp/chip" 'receiver: starting · reply overdue'
check 'overdue count independent' contains "$tmp/chip" '◷ 1'
check 'working count remains' contains "$tmp/chip" 'SPIN 1'
check 'no blink for overdue' absent "$tmp/chip" ',blink'
check 'state unchanged' test "$(tmux show -pqv -t "$receiver" @state)" = working
check 'attention unchanged' test -z "$(tmux show -pqv -t "$receiver" @attention_since)"
tmux set -p -t "$receiver" @request_pending_since 1999998199
list
check 'after threshold remains overdue' contains "$tmp/list" 'reply overdue'
# Another receiver needing permission must win focus over mere inactivity.
urgent="$(tmux split-window -d -h -t %0 -P -F '#{pane_id}' cat)"
tmux set -p -t "$urgent" @agent urgent
tmux set -p -t "$urgent" @parent %0
tmux set -p -t "$urgent" @perm_since 1999999999
chip
check 'real attention wins focus over overdue' contains "$tmp/chip" 'urgent: NEEDS PERMISSION'
check 'overdue still counted behind attention' contains "$tmp/chip" '◷ 1'
tmux kill-pane -t "$urgent"
tmux set -p -t "$receiver" @member 1
tmux set -p -t "$receiver" @parent %0
list
check 'overdue member visible' contains "$tmp/list" 'member of main'
chip
check 'overdue member focused' contains "$tmp/chip" 'receiver:'
for state in idle "done" needs_you; do
  tmux set -p -t "$receiver" @state "$state"
  list
  check "$state still shows overdue" contains "$tmp/list" 'reply overdue'
  case "$state" in idle) label='○ idle';; done) label='✓ done';; needs_you) label='◆ needs you';; esac
  check "$state label preserved" contains "$tmp/list" "$label"
done
for marker in msg_waiting_since perm_since; do
  tmux set -p -t "$receiver" "@$marker" 1999999900
  list
  case "$marker" in perm_since) label='⚠ permission';; *) label='✉ message waiting';; esac
  check "$marker priority retained" contains "$tmp/list" "$label"
  check "$marker badge retained" contains "$tmp/list" 'reply overdue'
  tmux set -pu -t "$receiver" "@$marker"
done
tmux set -p -t "$receiver" @state working
tmux set -p -t "$receiver" @request_progress_at 1999999999
list 'all · all windows> '
check 'recent progress resets inactivity' absent "$tmp/list" 'reply overdue'
chip
check 'recent progress hides ordinary member chip' test ! -s "$tmp/chip"
tmux set -p -t "$receiver" @request_progress_at 1999990000
list
check 'progress before pending uses pending' contains "$tmp/list" 'reply overdue'
export TMUX_AGENTS_REPLY_OVERDUE_SECS=0
list 'all · all windows> '
check 'env zero disables overdue' absent "$tmp/list" 'reply overdue'
chip
check 'env zero disables chip' test ! -s "$tmp/chip"
unset TMUX_AGENTS_REPLY_OVERDUE_SECS
tmux set -g @tmux_agents_reply_overdue_secs 0
list 'all · all windows> '
check 'option zero disables overdue' absent "$tmp/list" 'reply overdue'
export TMUX_AGENTS_REPLY_OVERDUE_SECS=1800
list
check 'env overrides option' contains "$tmp/list" 'reply overdue'
tmux set -pu -t "$receiver" @request_pending_since
list 'all · all windows> '
check 'no pending ignores old progress' absent "$tmp/list" 'reply overdue'
tmux set -p -t "$receiver" @request_pending_since 1999998200
export TMUX_AGENTS_REPLY_OVERDUE_SECS=invalid
list
check 'invalid timeout falls back to default' contains "$tmp/list" 'reply overdue'
# Preserve exited status and suppress stale overdue markers on dead panes.
tmux set -w -t "$receiver" remain-on-exit on
tmux send-keys -t "$receiver" C-d
for ((i=0; i<50; i++)); do
  [ "$(tmux display-message -p -t "$receiver" '#{pane_dead}')" != 1 ] || break
  sleep 0.1
done
check 'receiver exited' test "$(tmux display-message -p -t "$receiver" '#{pane_dead}')" = 1
list 'all · all windows> '
check 'dead receiver retains exited status' contains "$tmp/list" '✗ exited'
check 'dead receiver no overdue badge' absent "$tmp/list" 'reply overdue'
echo "$((count-fail))/$count passed"
[ "$fail" -eq 0 ]
