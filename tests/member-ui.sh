#!/usr/bin/env bash
# Member visibility, attention, helper counts and closed labels on a private server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-member-ui-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-member-ui.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir "$tmp/stubs"
for kind in claude codex; do
  printf '#!/bin/sh\necho MEMBER_UI_STUB\nexec cat\n' >"$tmp/stubs/$kind"
  chmod +x "$tmp/stubs/$kind"
done
export TMUX_SPAWN_BIN="$tmp/stubs"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=$((fail+1)); fi; }
# shellcheck disable=SC2329
has() { grep -q "^$2 " "$1"; }
# shellcheck disable=SC2329
lacks() { ! has "$@"; }
# shellcheck disable=SC2329
contains() { grep -Fq -- "$2" "$1"; }
# shellcheck disable=SC2329
absent() { ! contains "$@"; }
agent() { tmux set -p -t "$1" @agent "$2"; [ -z "${3:-}" ] || tmux set -p -t "$1" @parent "$3"; }
list() { FZF_PROMPT="$1" "$B/tmux-agents" --list | tr '\0' '\n' >"$tmp/list"; }
chip() { CHIP_SPIN=SPIN "$B/tmux-agents" --chip >"$tmp/chip"; }
agent %0 main
member="$(tmux new-session -d -s agents-project -c "$tmp" -P -F '#{pane_id}' "$tmp/stubs/codex")"
agent "$member" member %0
tmux set -p -t "$member" @member 1
helper="$(tmux new-window -d -t agents-project -c "$tmp" -P -F '#{pane_id}' "$tmp/stubs/claude")"
agent "$helper" helper "$member"
for p in "$member" "$helper"; do
  for ((i=0; i<50; i++)); do
    tmux capture-pane -p -t "$p" | grep -q MEMBER_UI_STUB && break
    sleep 0.1
  done
  tmux capture-pane -p -t "$p" | grep -q MEMBER_UI_STUB || { echo 'ABORT: stub not ready'; exit 1; }
done
for state in running idle "done"; do
  tmux set -p -t "$member" @state "$state"
  tmux set -p -t "$helper" @state "$state"
  for scope in 'this window' 'all windows'; do
    list "agents · $scope> "
    check "$state member excluded from sub $scope" lacks "$tmp/list" "$member"
    check "$state helper retained in sub $scope" has "$tmp/list" "$helper"
    list "all · $scope> "
    check "$state member included in all $scope" has "$tmp/list" "$member"
    check 'member owner label' contains "$tmp/list" 'member of main'
    check 'member project group' contains "$tmp/list" '▸ project'
  done
  chip
  case "$state" in running) counter='SPIN 1';; idle) counter='○ 1';; done) counter='✓ 1';; esac
  check "$state chip counts only helper" contains "$tmp/chip" "$counter"
  check "$state member not focused" absent "$tmp/chip" 'member:'
done
"$B/tmux-agents" --status >"$tmp/status"
check 'legacy status excludes member from done count' contains "$tmp/status" 'active subagents: 0 · 1 done'
# Put the member in another window tree: attention must still pin globally.
tmux set -pu -t "$member" @parent
other="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
agent "$other" other
tmux set -p -t "$member" @parent "$other"
now="$(date +%s)"
for attention in needs permission message; do
  tmux set -p -t "$member" @state running
  case "$attention" in
    needs) tmux set -p -t "$member" @state needs_you; tmux set -p -t "$member" @attention_since "$now"; label='◆ needs you'; focus='◆ member: NEEDS YOU'; counter=' ◆ 1 ';;
    permission) tmux set -p -t "$member" @perm_since "$now"; label='⚠ permission'; focus='⚠ member: NEEDS PERMISSION'; counter=' ⚠ 1 ';;
    message) tmux set -p -t "$member" @msg_waiting_since "$now"; label='✉ message waiting'; focus='✉ member: message waiting'; counter=' ✉ 1 ';;
  esac
  for mode in agents all; do
    list "$mode · this window> "
    check "$attention member pinned in $mode view" has "$tmp/list" "$member"
    check "$attention pinned section" contains "$tmp/list" '▸ needs you'
    check "$attention label" contains "$tmp/list" "$label"
    check "$attention owner" contains "$tmp/list" 'member of other'
    check "$attention no duplicate" test "$(grep -c "^$member " "$tmp/list")" = 1
  done
  chip
  check "$attention member focused" contains "$tmp/chip" "$focus"
  check "$attention count retained" contains "$tmp/chip" "$counter"
  check "$attention helper count intact" contains "$tmp/chip" '✓ 1'
  tmux set -pu -t "$member" @perm_since
  tmux set -pu -t "$member" @msg_waiting_since
done
tmux set -p -t "$member" @state running
tmux kill-pane -t "$helper"
chip
check 'member alone does not keep chip visible' test ! -s "$tmp/chip"
. "$B/lib.sh"
ensure_agent_ids "$tmp/queue"
records="$XDG_STATE_HOME/tmux-agents/${S##*/}/sessions"
mkdir -p "$records"
printf 'agent_id=a000000000001\nname=closed-member\nid=session\nmember=1\nparent=%s\ndir=%s\nclosed=%s\n' "$(pane_agent_id %0)" "$tmp" "$now" >"$records/a000000000001"
for mode in agents all; do
  list "$mode · this window> "
  check "closed member retained in $mode" has "$tmp/list" closed:a000000000001
  check 'closed section retained' contains "$tmp/list" '▸ closed (1)'
  check 'closed member owner label' contains "$tmp/list" 'member of main'
done
echo "$((count-fail))/$count passed"
[ "$fail" -eq 0 ]
