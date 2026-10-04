#!/usr/bin/env bash
# Receiver attention, list pinning and chip state on a private tmux server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-msg-waiting-ui-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-msg-waiting-ui.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
cleanup() { tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=$((fail+1)); fi; }
has() { grep -q "^$2 " "$1"; }
lacks() { ! has "$@"; }
contains() { grep -Fq -- "$2" "$1"; }
absent() { ! contains "$@"; }
agent() { tmux set -p -t "$1" @agent "$2"; [ -z "${3:-}" ] || tmux set -p -t "$1" @parent "$3"; }
list() { FZF_PROMPT="$1" "$B/tmux-agents" --list | tr '\0' '\n' >"$tmp/list"; }
chip() { CHIP_SPIN=SPIN "$B/tmux-agents" --chip >"$tmp/chip"; }
agent %0 main
local_agent="$(tmux split-window -d -h -t %0 -P -F '#{pane_id}' cat)"; agent "$local_agent" local %0
receiver="$(tmux new-window -d -t work -c "$tmp" -P -F '#{pane_id}' cat)"; agent "$receiver" receiver
unnamed="$(tmux new-window -d -t work -c "$tmp" -P -F '#{pane_id}' cat)"
need="$(tmux new-session -d -s agents-remote -c "$tmp" -P -F '#{pane_id}' cat)"; agent "$need" needs %0
perm="$(tmux new-window -d -t agents-remote -c "$tmp" -P -F '#{pane_id}' cat)"; agent "$perm" permission %0
. "$B/lib.sh"
ensure_agent_ids "$tmp/queue"
now="$(date +%s)"
tmux set -p -t "$receiver" @msg_waiting_since "$((now-300))"
tmux set -p -t "$receiver" @activity receiving
# A receiver need not have either a name or a parent.
tmux set -p -t "$unnamed" @msg_waiting_since "$((now-100))"
tmux set -p -t "$need" @state needs_you
tmux set -p -t "$need" @attention_since "$((now-400))"
tmux set -p -t "$perm" @perm_since "$((now-200))"
for prompt in 'agents · this window> ' 'agents · all windows> ' 'all · this window> ' 'all · all windows> '; do
  list "$prompt"
  check "$prompt pins unparented receiver" has "$tmp/list" "$receiver"
  check "$prompt pins unnamed receiver" has "$tmp/list" "$unnamed"
  check "$prompt no duplicate receiver" test "$(grep -c "^$receiver " "$tmp/list")" = 1
  check "$prompt attention oldest first" test "$(awk '/^%/ {print $1}' "$tmp/list" | head -4 | tr '\n' ' ')" = "$need $receiver $perm $unnamed "
done
check 'waiting list text is amber' contains "$tmp/list" $'\033[1;30;48;5;214m✉ message waiting\033[0m'
check 'receiver location and activity retained' contains "$tmp/list" "work:1 ·"
check 'unnamed receiver uses pane id as name' grep -Eq "^$unnamed +$unnamed +" "$tmp/list"
chip
check 'waiting count includes both unparented receivers' contains "$tmp/chip" '#[fg=black,bg=colour214,bold] ✉ 2 #[default]'
check 'permission count unchanged' contains "$tmp/chip" '#[fg=white,bg=red,bold] ⚠ 1 #[default]'
check 'needs-you count unchanged' contains "$tmp/chip" '#[fg=black,bg=colour214,bold] ◆ 1 #[default]'
# Leave exactly one attention candidate: focus must use the marker, not activity/state.
tmux set -pu -t "$unnamed" @msg_waiting_since
tmux set -pu -t "$need" @state
tmux set -pu -t "$perm" @perm_since
tmux set -p -t "$receiver" @state done
chip
check 'waiting focus overrides done and blinks after threshold' contains "$tmp/chip" '#[fg=black,bg=colour214,bold,blink] ✉ receiver: message waiting #[default]'
check 'receiver counted once' contains "$tmp/chip" ' ✉ 1 '
check 'receiver does not also count as done' absent "$tmp/chip" '✓ 1'
tmux set -p -t "$receiver" @msg_waiting_since "$(date +%s)"
chip
check 'fresh marker does not blink' contains "$tmp/chip" '#[fg=black,bg=colour214,bold] ✉ receiver: message waiting #[default]'
check 'fresh marker has no blink style' absent "$tmp/chip" ',blink'
tmux set -p -t "$receiver" @state needs_you
tmux set -p -t "$receiver" @attention_since "$((now-500))"
chip
check 'waiting timestamp wins over stale needs-you timestamp' absent "$tmp/chip" ',blink'
list 'agents · this window> '
check 'message label takes precedence over needs-you' contains "$tmp/list" '✉ message waiting'
tmux set -p -t "$receiver" @perm_since "$((now-300))"
chip
check 'permission focus takes precedence' contains "$tmp/chip" '#[fg=white,bg=red,bold,blink] ⚠ receiver: NEEDS PERMISSION'
check 'permission receiver not counted as waiting' absent "$tmp/chip" '✉'
list 'agents · this window> '
check 'permission list label takes precedence' contains "$tmp/list" '⚠ permission'
check 'permission list suppresses waiting label' absent "$tmp/list" '✉ message waiting'
tmux set -pu -t "$receiver" @perm_since
tmux set -pu -t "$receiver" @msg_waiting_since
list 'agents · this window> '
check 'cleared unparented receiver returns outside subagent view' lacks "$tmp/list" "$receiver"
check 'cleared unnamed receiver disappears' lacks "$tmp/list" "$unnamed"
chip
check 'cleared receiver disappears from chip' absent "$tmp/chip" 'receiver'
check 'cleared marker removes waiting counts' absent "$tmp/chip" '✉'
# Ordinary agent states remain intact, including restored state after delivery.
tmux set -p -t "$local_agent" @state idle
tmux set -p -t "$need" @state done
tmux set -p -t "$perm" @activity running
chip
check 'ordinary idle count preserved' contains "$tmp/chip" '#[fg=colour244]○ 1'
check 'ordinary done count preserved' contains "$tmp/chip" '#[fg=colour114]✓ 1'
check 'ordinary working count preserved' contains "$tmp/chip" '#[fg=colour117]SPIN 1#[default]'
tmux set -p -t "$local_agent" @msg_waiting_since "$((now-300))"
chip
check 'subagent waiting focus overrides idle' contains "$tmp/chip" '✉ local: message waiting'
list 'agents · this window> '
check 'local waiting agent appears once' test "$(grep -c "^$local_agent " "$tmp/list")" = 1
tmux set -pu -t "$local_agent" @msg_waiting_since
list 'agents · this window> '
check 'cleared local marker restores idle list state' contains "$tmp/list" '○ idle'
chip
check 'cleared local marker restores idle chip count' contains "$tmp/chip" '#[fg=colour244]○ 1'
# Stale marker on a dead pane must not hide exit status.
tmux set -w -t "$receiver" remain-on-exit on
tmux set -p -t "$receiver" @msg_waiting_since "$((now-300))"
tmux send-keys -t "$receiver" C-d
for i in {1..50}; do [ "$(tmux display-message -p -t "$receiver" '#{pane_dead}')" != 1 ] || break; sleep 0.1; done
list 'agents · all windows> '
check 'dead receiver uses exited list status' contains "$tmp/list" '✗ exited'
chip
check 'dead receiver uses exited count' contains "$tmp/chip" '#[fg=colour240]✗ 1'
check 'dead marker does not retain waiting count' absent "$tmp/chip" '✉'
# The marker alone keeps the chip visible, without any subagents.
for p in "$local_agent" "$need" "$perm" "$receiver"; do tmux kill-pane -t "$p"; done
tmux set -p -t "$unnamed" @msg_waiting_since "$((now-300))"
chip
check 'sole unnamed receiver has waiting focus' contains "$tmp/chip" "✉ $unnamed: message waiting"
check 'sole unnamed receiver has waiting count' contains "$tmp/chip" ' ✉ 1 '
tmux set -pu -t "$unnamed" @msg_waiting_since
chip
check 'no subagents or markers means empty chip' test ! -s "$tmp/chip"
# Batched record loading preserves mtime fallback, pruning and id-less ancestry.
records="$XDG_STATE_HOME/tmux-agents/${S##*/}/sessions"
mkdir -p "$records"
main_id="$(pane_agent_id %0)"
printf 'agent_id=a000000000001\nname=fallback\nid=fallback\ndir=%s\nparent=%s\n' "$tmp" "$main_id" >"$records/a000000000001"
printf 'agent_id=a000000000002\nname=expired\nid=expired\nclosed=%s\n' "$((now-8*86400))" >"$records/a000000000002"
printf 'agent_id=a000000000003\nname=bridge\nparent=%s\nclosed=%s\n' "$main_id" "$now" >"$records/a000000000003"
printf 'agent_id=a000000000004\nname=child\nid=child\nparent=a000000000003\ndir=%s\nclosed=%s\n' "$tmp" "$now" >"$records/a000000000004"
printf 'agent_id=%s\nname=main\nid=live\nparent=%s\ndir=%s\nclosed=%s\n' "$main_id" "$main_id" "$tmp" "$now" >"$records/$main_id"
list 'agents · this window> '
check 'record without closed timestamp uses mtime' has "$tmp/list" closed:a000000000001
check 'closed child can traverse id-less record' has "$tmp/list" closed:a000000000004
check 'id-less record is not itself selectable' lacks "$tmp/list" closed:a000000000003
check 'live pane record is excluded' lacks "$tmp/list" "closed:$main_id"
check 'expired record is omitted' lacks "$tmp/list" closed:a000000000002
check 'expired record is removed' test ! -f "$records/a000000000002"
echo "$((count-fail))/$count passed"
[ "$fail" -eq 0 ]
