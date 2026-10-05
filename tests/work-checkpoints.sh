#!/usr/bin/env bash
# Checkpoints survive abrupt removal; real hooks close records in batches.
# All processes and records belong to a private tmux server; no live agents run.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-work-checkpoints-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-work-checkpoints.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project"
for kind in claude codex; do
  printf '#!/bin/sh\necho "STUB READY %s"\nexec cat\n' "$kind" >"$tmp/bin/$kind"
  chmod +x "$tmp/bin/$kind"
done
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project" cat </dev/null
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/queue"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
opt() { tmux show -pqv -t "$1" "@$2"; }
expect() { check "$1" test "$(opt "$2" "$3")" = "$4"; }
# Load the actual hooks, with every command pointed at this checkout/private server.
tmux set-environment -g TMUX_AGENTS_BIN "$B"
tmux source-file "$here/tmux/tmux-agents.conf"
tmux set -g @tmux_agents_chip_fps 1
# Invoked through check.
# shellcheck disable=SC2329
wait_closed() {
  local id="$1" i
  for ((i=0;i<100;i++)); do
    [ -z "$(record_get "$id" closed)" ] || return 0
    sleep .05
  done
  return 1
}
"$B/tmux-spawn" claude --from main --name checkpoint --exact </dev/null >"$tmp/spawn"
pane="$(find_pane checkpoint)"; id="$(pane_agent_id "$pane")"
record_set "$id" id checkpoint-conversation
check 'spawn records pane binding' test "$(record_get "$id" pane)" = "$pane"
agent_set_state "$pane" working 100
agent_set_state "$pane" "done" 130
check 'completed work saved without dismiss' test "$(record_get "$id" worked)" = 30
check 'completed turn saved' test "$(record_get "$id" turns)" = 1
check 'completed last turn saved' test "$(record_get "$id" last_turn)" = 30
check 'completed state time saved' test "$(record_get "$id" state_since)" = 130
agent_set_state "$pane" working 200
agent_set_wait "$pane" perm 210 210
check 'pause checkpoints accrued work' test "$(record_get "$id" worked)" = 40
check 'pause preserves completed turn count' test "$(record_get "$id" turns)" = 1
check 'pause clears saved active start' test "$(record_get "$id" turn_start)" = ''
agent_set_wait "$pane" perm '' 230
check 'active start checkpoints on resume' test "$(record_get "$id" turn_start)" = 230
# Abrupt removal cannot save the interval beginning at 230, but keeps 40 seconds.
tmux kill-pane -t "$pane"
check 'real after-kill hook closes record' wait_closed "$id"
check 'abrupt kill preserves completed and paused work' test "$(record_get "$id" worked)" = 40
check 'sweep clears lost active start without charging it' test "$(record_get "$id" turn_start)" = ''
"$B/tmux-spawn" --from main --resume-id "$id" </dev/null >"$tmp/resume"
pane="$(find_pane checkpoint)"
expect 'resume restores checkpointed total' "$pane" worked 40
check 'resume clears closed' test "$(record_get "$id" closed)" = ''
check 'resume updates pane binding' test "$(record_get "$id" pane)" = "$pane"
agent_set_state "$pane" working 300
agent_set_state "$pane" "done" 320
check 'resume adds a new completed turn' test "$(record_get "$id" worked)" = 60
check 'resume keeps completed turn count' test "$(record_get "$id" turns)" = 2
# Closing a window must also close records for all panes that disappeared.
win="$(tmux display -p -t "$pane" '#{window_id}')"
second="$(tmux split-window -d -t "$pane" -P -F '#{pane_id}' cat)"
set_name "$second" second
second_id="$(pane_agent_id "$second")"
agent_set_state "$second" working 400
agent_set_state "$second" idle 410
tmux kill-window -t "$win"
check 'window-unlinked closes first record' wait_closed "$id"
check 'window-unlinked closes second record' wait_closed "$second_id"
check 'window close retains totals' test "$(record_get "$second_id" worked)" = 10
# Natural exit without remain-on-exit leaves no pane, but the hook has the record.
exiting="$(tmux new-window -d -P -F '#{pane_id}' cat)"
set_name "$exiting" exiting
exit_id="$(pane_agent_id "$exiting")"
agent_set_state "$exiting" working 500
agent_set_state "$exiting" "done" 515
tmux set -p -t "$exiting" remain-on-exit off
tmux send-keys -t "$exiting" C-d
check 'pane-exited closes checkpointed record' wait_closed "$exit_id"
check 'natural exit retains total' test "$(record_get "$exit_id" worked)" = 15
# Live records are untouched and an already closed timestamp remains stable.
main_id="$(pane_agent_id %0)"
agent_set_state %0 working 600
closed_at="$(record_get "$id" closed)"
agent_sweep_closed
check 'sweep keeps live record open' test "$(record_get "$main_id" closed)" = ''
check 'sweep is idempotent for closed time' test "$(record_get "$id" closed)" = "$closed_at"
# Rebinding between candidate read and lock acquisition must survive the sweep.
rebind_id=a00000000abcd
record_set "$rebind_id" pane %999999
record_set "$rebind_id" worked 17
CHECKPOINT_REAL_TMUX="$(command -v tmux)"
CHECKPOINT_RECORD="$(sessions_dir)/$rebind_id"
export CHECKPOINT_REAL_TMUX CHECKPOINT_RECORD CHECKPOINT_COUNT="$tmp/snapshot-count"
mkdir "$tmp/shim"
cat >"$tmp/shim/tmux" <<'SH'
#!/bin/sh
if [ "$1" = list-panes ]; then
  printf 'snapshot\n' >>"$CHECKPOINT_COUNT"
  "$CHECKPOINT_REAL_TMUX" "$@" || exit
  printf 'agent_id=a00000000abcd\npane=%%0\nworked=17\n' >"$CHECKPOINT_RECORD"
else
  exec "$CHECKPOINT_REAL_TMUX" "$@"
fi
SH
chmod +x "$tmp/shim/tmux"
PATH="$tmp/shim:$PATH" agent_sweep_closed
check 'sweep preserves concurrently rebound record' test "$(record_get "$rebind_id" closed)" = ''
check 'sweep uses exactly one pane snapshot' test "$(cat "$CHECKPOINT_COUNT")" = snapshot
if [ "$fail" = 0 ]; then echo 'all passed'; else echo 'some failed'; exit 1; fi
