#!/usr/bin/env bash
# Command rows, persistence, scope, batched reads and dual shortcut migration.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-test-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
unset TMUX_AGENTS_SHELL_KEY TMUX_AGENTS_COMMAND_KEY
export XDG_STATE_HOME="$tmp/state"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 60 -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
agent() { tmux set -p -t "$1" @tracked 1; tmux set -p -t "$1" @agent "$2"; [ -z "${3:-}" ] || tmux set -p -t "$1" @parent "$3"; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
has() { grep -q "^$2 " "$1"; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
lacks() { ! has "$@"; }
agent %0 main-a
export TMUX_PANE=%0
origin="$(tmux display-message -p -t %0 '#{window_id}')"
other="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
agent "$other" main-b
"$B/tmux-agents" --list >/dev/null
owner="$(tmux show-options -pqv -t "$other" @agent_id)"
d="$XDG_STATE_HOME/tmux-agents/${S##*/}/commands"
mkdir -p "$d"
record() {
  cat >"$d/$1.record" <<EOF
command_id=$1
name=command-$1
pane=${2:-%9999}
parent=${3:-}
parent_name=main-b
origin_window=$origin
dir=$tmp
command=printf command-$1
status=$4
exit_code=0
created=1
EOF
  printf 'printf command-%s\n' "$1" >"$d/$1.command"
}
record c000000000001 %9999 '' ok
record c000000000002 %9998 "$owner" 'failed 7'
record c000000000003 %9997 '' running
list() { FZF_PROMPT="$1" "$B/tmux-agents" --list | tr '\0' '\n' >"$2"; }
list 'agents · this window> ' "$tmp/local"
check 'old command record never expires' test -f "$d/c000000000001.record"
check 'completed independent command remains in sub view' has "$tmp/local" command:c000000000001
check 'command status ok is shown' grep -q ok "$tmp/local"
check 'owned closed command follows owner, not origin' lacks "$tmp/local" command:c000000000002
check 'running command record shown' has "$tmp/local" command:c000000000003
export TMUX_PANE="$other"
list 'agents · this window> ' "$tmp/other"
check 'owned command follows live owner window' has "$tmp/other" command:c000000000002
check 'failed exit status is shown' grep -q 'failed 7' "$tmp/other"
export TMUX_PANE=%0
live="$(tmux new-session -d -s agents-command-ui -P -F '#{pane_id}' cat)"
tmux set -p -t "$live" @shell 1
tmux set -p -t "$live" @agent command-live
tmux set -p -t "$live" @shell_origin_window "$origin"
tmux set -p -t "$live" @shell_command_id c000000000003
tmux set -p -t "$live" @shell_command 'printf live-command'
tmux set -p -t "$live" @shell_status running
list 'agents · this window> ' "$tmp/live"
check 'live command pane shown' has "$tmp/live" "$live"
check 'matching record suppressed while live' lacks "$tmp/live" command:c000000000003
check 'live command text is shown' grep -q 'printf live-command' "$tmp/live"
check 'live command status is shown' grep -q running "$tmp/live"
tmux set -p -t "$live" @shell_status 'failed 9'
list 'agents · this window> ' "$tmp/failed"
check 'live failure status is shown' grep -q 'failed 9' "$tmp/failed"
tmux kill-pane -t "$live"
list 'agents · this window> ' "$tmp/closed"
check 'closed command record returns after pane exit' has "$tmp/closed" command:c000000000003
"$B/tmux-agents" --command-info command:c000000000001 >"$tmp/details"
check 'closed details include full raw command' grep -q 'printf command-c000000000001' "$tmp/details"
check 'closed details do not offer resume' grep -q 'cannot be reopened' "$tmp/details"
# Capture one list build: records share the same stat and awk process.
mkdir "$tmp/bin"
export COMMAND_UI_LOG="$tmp/calls"
for tool in tmux stat awk; do
  real="$(command -v "$tool")"
  cat >"$tmp/bin/$tool" <<EOF
#!/bin/sh
printf '%s\n' '$tool '"\$*" >>"\$COMMAND_UI_LOG"
exec '$real' "\$@"
EOF
  chmod +x "$tmp/bin/$tool"
done
PATH="$tmp/bin:$PATH" "$B/tmux-agents" --list >/dev/null
check 'one pane snapshot per list build' test "$(grep -c '^tmux list-panes -a' "$COMMAND_UI_LOG")" = 1
check 'one batched stat for all records' test "$(grep -c '^stat ' "$COMMAND_UI_LOG")" = 1
check 'one record awk read' test "$(grep -c '^awk .*tmux-agents-records.awk' "$COMMAND_UI_LOG")" = 1
# Clearing records never enters agent resume, and live commands clear by ID.
"$B/tmux-agents" --dismiss command:c000000000001
check 'clear closed command removes metadata' test ! -f "$d/c000000000001.record"
check 'clear closed command removes raw text' test ! -f "$d/c000000000001.command"
live="$(tmux new-session -d -s agents-command-clear -P -F '#{pane_id}' cat)"
tmux set -p -t "$live" @shell 1
tmux set -p -t "$live" @agent command-clear
tmux set -p -t "$live" @shell_command_id c000000000004
record c000000000004 "$live" '' running
"$B/tmux-agents" --dismiss "$live"
check 'clear live command removes record' test ! -f "$d/c000000000004.record"
check 'clear live command removes raw text' test ! -f "$d/c000000000004.command"
check 'clear live command closes matching pane' test -z "$(tmux list-panes -a -F '#{pane_id}' | grep -Fx "$live" || true)"
# Simulate the previous release's remembered C-s shell binding.
tmux bind-key -T prefix C-s run-shell old-shell
tmux set -g @tmux_agents_shell_bound_key C-s
tmux set -g @tmux_agents_shell_bound_command "$(tmux list-keys -T prefix C-s)"
"$B/tmux-agents" --shell-binding
check 'default S opens plain shell' test -n "$(tmux list-keys -T prefix S | grep tmux-shell)"
check 'migration C-s opens command picker' test -n "$(tmux list-keys -T prefix C-s | grep -- --pick)"
tmux set -g @tmux_agents_shell_key C-s
tmux set -g @tmux_agents_command_key S
"$B/tmux-agents" --shell-binding
check 'swapped S opens command picker' test -n "$(tmux list-keys -T prefix S | grep -- --pick)"
check 'swapped C-s remains plain shell' test "$(tmux list-keys -T prefix C-s | grep -c -- --pick || true)" = 0
before="$(tmux list-keys -T prefix)"
tmux set -g @tmux_agents_command_key C-s
if "$B/tmux-agents" --shell-binding >"$tmp/collision" 2>&1; then fail=1; echo 'FAIL duplicate keys accepted'; fi
check 'collision explains how to fix settings' grep -q 'choose distinct keys' "$tmp/collision"
check 'collision does not mutate existing bindings' test "$before" = "$(tmux list-keys -T prefix)"
tmux set -g @tmux_agents_shell_key none
tmux set -g @tmux_agents_command_key none
"$B/tmux-agents" --shell-binding
check 'disable clears shell binding' test -z "$(tmux list-keys -T prefix C-s 2>/dev/null || true)"
check 'disable clears command binding' test -z "$(tmux list-keys -T prefix S 2>/dev/null || true)"
TMUX_AGENTS_COMMAND_KEY=F8 "$B/tmux-agents" --shell-binding
check 'nonempty command env overrides none' test -n "$(tmux list-keys -T prefix F8 | grep -- --pick)"
tmux bind-key -T prefix F8 display-message user-command
TMUX_AGENTS_COMMAND_KEY='' "$B/tmux-agents" --shell-binding
check 'disable preserves replacement user command' test -n "$(tmux list-keys -T prefix F8 | grep user-command)"
[ "$fail" -eq 0 ] && echo 'all passed' || echo 'some failed'
exit "$fail"
