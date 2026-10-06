#!/usr/bin/env bash
# Named-pane takeover requires its own stdin tty and preserves connections.
# Child-shell commands intentionally contain unexpanded dollars.
# shellcheck disable=SC2016
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-start-takeover-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-start-takeover.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  cat > "$tmp/bin/$a" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\n' ready > "$TEST_LOG/$TMUX_PANE.ready"
exec cat
STUB
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH FROM_PANE
unset TMUX_AGENTS_NAME_FORMAT TMUX_START_NAME_EXACT TMUX_START_CHAIN_WORK
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TEST_LOG="$tmp"
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
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
info() { tmux display -p -t "$1" "#{@$2}"; }
wait_file() { local i; for ((i=0;i<200;i++)); do [ ! -s "$1" ] || return 0; sleep .05; done; return 1; }
# Snapshot every pane option and every state file, including migration markers.
snapshot() {
  python3 - "$XDG_STATE_HOME" <<'PY'
import pathlib, subprocess, sys
panes=subprocess.check_output(['tmux','list-panes','-a','-F','#{pane_id}']).splitlines()
for pane in sorted(panes):
    print(pane, subprocess.check_output(['tmux','show-options','-p','-t',pane.decode()]))
root=pathlib.Path(sys.argv[1])
for p in sorted(root.rglob('*')):
    print(str(p.relative_to(root)), p.read_bytes() if p.is_file() else 'directory')
PY
}
quote_command() { python3 - "$@" <<'PY'
import shlex,sys
print(shlex.join(sys.argv[1:]))
PY
}
# Use an actual interactive shell, first running a manually launched agent.
pane="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp")"
tmux send-keys -t "$pane" -l "$(quote_command "$tmp/bin/codex")"
tmux send-keys -t "$pane" Enter
wait_file "$tmp/$pane.ready"
check 'direct stub started' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE codex"' _ "$pane"
tmux send-keys -t "$pane" C-d
# Seed a legacy named pane without an ID, before migration has ever run.
tmux set -p -t "$pane" @agent stale-label
tmux set -p -t "$pane" @activity stale
snapshot > "$tmp/before"
if TMUX_PANE="$pane" "$B/tmux-agents-start" codex </dev/null > "$tmp/error" 2>&1; then
  echo 'FAIL no-tty launch accepted'; fail=1
fi
snapshot > "$tmp/after"
check 'no tty rejects without any state or migration changes' cmp "$tmp/before" "$tmp/after"
check 'refusal names the pane and explains own terminal' grep -q "pane 'stale-label'.*not running from its own terminal" "$tmp/error"
check 'refusal explains shell or fresh pane recovery' grep -q 'quit the agent.*shell.*fresh pane' "$tmp/error"
# A real tty belonging to another pane must also fail before migration.
other="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp")"
snapshot > "$tmp/before"
cmd="$(quote_command env "TMUX_PANE=$pane" "$B/tmux-agents-start" codex)"
error="$(quote_command "$tmp/different-error")"
status="$(quote_command "$tmp/different-status")"
tmux send-keys -t "$other" -l "$cmd >$error 2>&1; echo \$? >$status"
tmux send-keys -t "$other" Enter
wait_file "$tmp/different-status"
snapshot > "$tmp/after"
check 'different tty returns failure' test "$(cat "$tmp/different-status")" != 0
check 'different tty preserves all state' cmp "$tmp/before" "$tmp/after"
check 'different tty explains refusal' grep -q 'not running from its own terminal' "$tmp/different-error"
# Establish an old identity, a connected child and stale state of every kind.
set_name "$pane" stale-label
set_name %0 peer-label
old_id="$(pane_agent_id "$pane")"
record_set "$old_id" name stale-label
record_set "$old_id" kind codex
record_set "$old_id" id old-thread
add_peer "$pane" %0
add_peer %0 "$pane"
tmux set -p -t %0 @parent "$pane"
for key in tracked member state_since worked last_turn turns turn_start turn_work turn_active started perm_since msg_waiting_since work_closed work_restored attention_since; do
  tmux set -p -t "$pane" "@$key" 1
done
for key in parent closed activity awaiting waiting_on codex_thread; do
  tmux set -p -t "$pane" "@$key" stale
done
tmux set -p -t "$pane" @state needs_you
refresh_labels
old_peers="$(info "$pane" peers)" old_labels="$(info "$pane" peer_names)"
peer_peers="$(info %0 peers)" peer_labels="$(info %0 peer_names)"
rm "$tmp/$pane.ready"
cmd="$(quote_command "$B/tmux-agents-start" codex --name ignored-name)"
tmux send-keys -t "$pane" -l "$cmd; echo finished > $(quote_command "$tmp/finished")"
tmux send-keys -t "$pane" Enter
if ! wait_file "$tmp/$pane.ready"; then
  tmux capture-pane -p -t "$pane"
  echo 'FAIL own-terminal takeover did not launch'; exit 1
fi
new_id="$(pane_agent_id "$pane")"
check 'takeover preserves existing label despite --name' test "$(info "$pane" agent)" = stale-label
check 'takeover assigns fresh ID' test "$new_id" != "$old_id"
check 'new ID is valid' valid_agent_id "$new_id"
check 'takeover is tracked and idle' test "$(info "$pane" tracked):$(info "$pane" state)" = 1:idle
check 'takeover starts with zero work' test "$(info "$pane" worked)" = 0
check 'takeover is not a member' test "$(info "$pane" member)" = 0
check 'takeover preserves peers and labels' test "$(info "$pane" peers):$(info "$pane" peer_names)" = "$old_peers:$old_labels"
check 'takeover preserves reverse peers and labels' test "$(info %0 peers):$(info %0 peer_names)" = "$peer_peers:$peer_labels"
check 'takeover detaches old child parent link' test -z "$(info %0 parent)"
check 'old record closed' test -n "$(record_get "$old_id" closed)"
check 'old conversation preserved' test "$(record_get "$old_id" id)" = old-thread
check 'peer receives old identity closure' test "$(info %0 closed)" = "$old_id"
check 'new record describes preserved name and launcher' test "$(record_get "$new_id" name):$(record_get "$new_id" launcher)" = stale-label:1
check 'new record is open' test -z "$(record_get "$new_id" closed)"
for key in parent closed last_turn turn_start turn_work turn_active perm_since msg_waiting_since work_closed work_restored activity awaiting waiting_on attention_since codex_thread; do
  check "takeover clears @$key" test -z "$(info "$pane" "$key")"
done
# Exiting the new child still does ordinary disconnect-and-clear cleanup.
tmux send-keys -t "$pane" C-d
wait_file "$tmp/finished"
check 'normal exit clears name identity and peers' test -z "$(info "$pane" agent)$(info "$pane" agent_id)$(info "$pane" peers)$(info "$pane" peer_names)"
check 'normal exit disconnects reverse peers' test -z "$(info %0 peers)"
check 'normal exit closes new record' test -n "$(record_get "$new_id" closed)"
# The same shell is now fresh: ordinary unnamed launch remains supported.
rm "$tmp/$pane.ready"
tmux send-keys -t "$pane" -l "$(quote_command env TMUX_AGENTS_NAME_FORMAT=exact "$B/tmux-agents-start" claude --name fresh-label)"
tmux send-keys -t "$pane" Enter
wait_file "$tmp/$pane.ready"
check 'fresh unnamed pane launches normally' test "$(info "$pane" agent):$(info "$pane" tracked):$(info "$pane" state)" = fresh-label:1:idle
check 'fresh Claude stub marker' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE claude"' _ "$pane"
exit "$fail"
