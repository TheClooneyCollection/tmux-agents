#!/usr/bin/env bash
# Visible exit shells, retained hidden/dead panes, settings and identity cleanup.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-sub-exit-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-sub-exit.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  printf '#!/bin/sh\necho "FAKE %s"\nexec cat\n' "$a" > "$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_SUB_EXIT
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 70 -c "$tmp" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
. "$B/lib.sh"
set_name %0 main
tmux set -g @tmux_agents_chip_fps 1
# Install the shipped hook verbatim, without starting the configuration's UI.
sed -n '/^set-hook -g pane-died\[42\]/p' "$here/tmux/tmux-agents.conf" | sed "s|\$TMUX_AGENTS_BIN|$B|g" > "$tmp/hook.conf"
tmux source-file "$tmp/hook.conf"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
info() { tmux display -p -t "$1" "#{$2}"; }
wait_for() { local i; for ((i=0;i<200;i++)); do if "$@"; then return 0; fi; sleep .05; done; return 1; }
# shellcheck disable=SC2329
started() { tmux capture-pane -p -t "$1" | grep -q "FAKE $2"; }
# shellcheck disable=SC2329
cleared() { [ -z "$(info "$1" @agent_id)" ]; }
# shellcheck disable=SC2329
dead() { [ "$(info "$1" pane_dead)" = 1 ]; }
# shellcheck disable=SC2329
shell_running() { [ "$(info "$1" pane_current_command)" = sh ]; }
# shellcheck disable=SC2329
saved() { [ "$(record_get "$1" worked)" = 37 ]; }
spawn() {
  local kind="$1" name="$2"; shift 2
  TMUX_PANE=%0 "$B/tmux-spawn" "$kind" --from main --exact --name "$name" "$@" </dev/null > "$tmp/spawn"
  child="$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$name" '$2 == n {print $1}')"
  wait_for started "$child" "$kind"
  id="$(pane_agent_id "$child")"
}
seed_work() {
  # Completed deterministic work avoids dependence on wall-clock boundaries.
  agent_set_state "$child" working 100
  agent_set_state "$child" "done" 137
  record_set "$id" worked 0
}
spawn claude shell-child --split main
check 'default split does not enable remain-on-exit' test "$(tmux show-options -pqv -t "$child" remain-on-exit)" != on
seed_work
owned="$(tmux new-window -d -P -F '#{pane_id}' cat)"
set_name "$owned" owned
tmux set -p -t "$owned" @parent "$child"
for key in member perm_since msg_waiting_since attention_since awaiting waiting_on codex_thread request_local_work; do tmux set -p -t "$child" "@$key" stale; done
tmux send-keys -t "$child" C-d
check 'exit clears identity' wait_for cleared "$child"
check 'visible pane survives' test "$(info "$child" pane_dead)" = 0
check 'record closes' test -n "$(record_get "$id" closed)"
check 'work saved before clearing' saved "$id"
check 'conversation retained' test -n "$(record_get "$id" id)"
for key in agent agent_id tracked parent member peers peer_names closed state state_since worked last_turn turns turn_start turn_work turn_active started perm_since msg_waiting_since work_closed work_restored activity awaiting waiting_on attention_since codex_thread request_local_work request_local_done request_notify_digest request_progress_at request_pending_since; do
  check "exit clears @$key" test -z "$(info "$child" "@$key")"
done
check 'reverse peers disconnected' test -z "$(info %0 @peers)"
check 'direct child becomes unowned' test -z "$(info "$owned" @parent)"
check 'parent learns closed identity' test "$(info %0 @closed)" = "$id"
check 'shell process starts' wait_for shell_running "$child"
tmux send-keys -t "$child" -l "printf shell-ready > '$tmp/shell-ready'"
tmux send-keys -t "$child" Enter
check 'default shell accepts commands' wait_for test -s "$tmp/shell-ready"
tmux kill-pane -t "$child"
TMUX_PANE=%0 "$B/tmux-spawn" --from main --resume-id "$id" </dev/null > "$tmp/resume"
child="$(tmux list-panes -a -F '#{pane_id} #{@agent_id}' | awk -v id="$id" '$2 == id {print $1}')"
check 'resume starts Claude stub' wait_for started "$child" claude
check 'resume returns in hidden session' test "$(info "$child" session_name)" != work
tmux send-keys -t "$child" C-d
check 'resumed shell split retains dead pane' wait_for dead "$child"
spawn codex hidden-child
seed_work
tmux send-keys -t "$child" C-d
check 'hidden default remains dead' wait_for dead "$child"
check 'hidden hook saves worked time' wait_for saved "$id"
check 'hidden identity retained' test "$(pane_agent_id "$child")" = "$id"
tmux set -g @tmux_agents_sub_exit keep
spawn claude keep-child --split main
seed_work
tmux send-keys -t "$child" C-d
check 'keep split remains dead' wait_for dead "$child"
check 'keep hook saves worked time' wait_for saved "$id"
check 'keep split retains agent identity' test "$(pane_agent_id "$child")" = "$id"
TMUX_AGENTS_SUB_EXIT=shell spawn codex env-shell --split main
tmux send-keys -t "$child" C-d
check 'environment shell overrides option keep' wait_for cleared "$child"
tmux kill-pane -t "$child"
tmux set -g @tmux_agents_sub_exit shell
# A replacement identity in the same pane must survive the old child's exit.
spawn claude guarded --split main
replacement="$(new_agent_id)"
tmux set -p -t "$child" @agent_id "$replacement"
tmux set -p -t "$child" @activity replacement-state
tmux send-keys -t "$child" C-d
check 'identity guard returns to shell' wait_for shell_running "$child"
check 'old exit preserves replacement identity' test "$(pane_agent_id "$child")" = "$replacement"
check 'old exit preserves replacement options' test "$(info "$child" @activity)" = replacement-state
tmux kill-pane -t "$child"
TMUX_AGENTS_SUB_EXIT=keep spawn claude env-keep --split main
tmux send-keys -t "$child" C-d
check 'environment keep overrides option shell' wait_for dead "$child"
before="$(tmux list-panes -a -F '#{pane_id}')"
if TMUX_AGENTS_SUB_EXIT=invalid TMUX_PANE=%0 "$B/tmux-spawn" claude --from main --split main </dev/null > "$tmp/error" 2>&1; then
  echo 'FAIL invalid environment accepted'; fail=1
fi
check 'invalid value names setting' grep -q 'sub_exit\|SUB_EXIT' "$tmp/error"
check 'invalid value creates no pane' test "$(tmux list-panes -a -F '#{pane_id}')" = "$before"
tmux set -g @tmux_agents_sub_exit invalid
if TMUX_PANE=%0 "$B/tmux-spawn" claude --from main --split main </dev/null > "$tmp/error" 2>&1; then
  echo 'FAIL invalid option accepted'; fail=1
fi
check 'invalid option creates no pane' test "$(tmux list-panes -a -F '#{pane_id}')" = "$before"
[ "$fail" -ne 0 ] || echo 'all passed'
exit "$fail"
