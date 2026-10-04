#!/usr/bin/env bash
# Durable queue regression tests; all tmux operations use an isolated server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-ask-test-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-ask-test.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_QUEUE_SECS=1 TMUX_ASK_COPY_IDLE_SECS=0
Q="/tmp/tmux-agents-$(id -u)/queue/$sock"
legacy="/tmp/tmux-agents-$(id -u)/queue/100-$$-99.undelivered"
cleanup() {
  tmux -L "$sock" kill-server 2>/dev/null || true
  rm -rf "$state_dir" "$Q"
  rm -f "$legacy"
}
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -x 150 -y 40 cat
tmux -L "$sock" has-session || { echo 'ABORT: no test server'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0"
tmux set-option -g default-shell /bin/sh
tmux new-window -d cat
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"
receiver_id="$(pane_agent_id %1)"
count=0
check() { if "$@"; then count=$((count + 1)); echo "ok $count: $*"; else echo "FAIL: $*"; exit 1; fi; }
wait_for() { local n; for n in $(seq 1 60); do "$@" && return 0; sleep .1; done; return 1; }
chip_on() { [ "$(tmux show -gv status)" = 2 ]; }
marked() { [ -n "$(tmux show -pqv -t %1 @msg_waiting_since)" ]; }
cleared() { [ -z "$(tmux show -pqv -t %1 @msg_waiting_since)" ]; }
no_queued() { [ -z "$(find "$Q" -name '*.msg' -o -name '*.sending')" ]; }
not_captured() { ! captured "$@"; }
captured() { tmux capture-pane -p -S - -t "$1" | grep -q "$2"; }
# Suppress only automatic loop startup so tests can own/stop worker PIDs.
mkdir "$state_dir/manual-bin"
real_tmux="$(command -v tmux)"
cat > "$state_dir/manual-bin/tmux" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = run-shell ]; then case "\${3:-}" in *--deliver*) exit "\${TMUX_ASK_TEST_FAIL_RUN:-0}" ;; esac; fi
exec '$real_tmux' "\$@"
WRAP
chmod +x "$state_dir/manual-bin/tmux"
ask() { PATH="$state_dir/manual-bin:$PATH" "$B/tmux-ask" --from sender receiver "$1" </dev/null; }
tmux copy-mode -t %1
ask durable-one
ask durable-two
first="$(find "$Q" -name '*.msg' | sort | head -n 1)"
"$B/tmux-ask" --deliver %1 "$first" </dev/null &
worker=$!
check wait_for marked
check wait_for chip_on
kill "$worker"
wait "$worker" || true
sleep .2
check test "$(find "$Q" -name '*.msg' | wc -l | tr -d ' ')" = 2
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 0
"$B/tmux-ask" --pending > "$state_dir/pending" </dev/null
check grep -q 'sender.*receiver.*msg' "$state_dir/pending"
tmux send-keys -t %1 -X cancel
# Fail the second paste: the first delivery must leave the waiting marker.
mkdir "$state_dir/fail-bin"
real_tmux="$(command -v tmux)"
cat > "$state_dir/fail-bin/tmux" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = paste-buffer ]; then
  body="\$('$real_tmux' show-buffer -b "\$5")"
  case "\$body" in *durable-two*) exit 1 ;; esac
fi
exec '$real_tmux' "\$@"
WRAP
chmod +x "$state_dir/fail-bin/tmux"
PATH="$state_dir/fail-bin:$PATH" "$B/tmux-ask" --kick %1 </dev/null
check marked
check test "$(find "$Q" -name '*.msg' | wc -l | tr -d ' ')" = 1
check test "$(find "$Q" -name '*.sending' | wc -l | tr -d ' ')" = 0
"$B/tmux-ask" --kick %1 </dev/null &
"$B/tmux-ask" --kick %1 </dev/null &
wait
check wait_for no_queued
check cleared
check captured %1 durable-one
check captured %1 durable-two
# A dead receiver bounces, and a session id promises automatic reopen delivery.
tmux copy-mode -t %1
ask lost-but-kept
mkdir -p "$state_dir/tmux-agents/$sock/sessions"
record_set "$receiver_id" name receiver
record_set "$receiver_id" id test-session
tmux kill-pane -t %1
tmux set -p -t %0 @agent renamed-sender
lost="$(find "$Q" -name '*.msg' | head -n 1)"
"$B/tmux-ask" --deliver %1 "$lost" </dev/null
check wait_for captured %0 'notice from tmux-ask to renamed-sender'
check captured %0 'will be delivered if receiver is reopened'
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 1
"$B/tmux-ask" --retry --to receiver </dev/null > "$state_dir/retry"
check grep -q unplaced "$state_dir/retry"
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 1
# Unattributed legacy headers stay visible but cannot prove identity.
printf '[reply from old-sender to receiver via tmux-ask]\nlegacy-body\n' > "$legacy"
"$B/tmux-ask" --pending </dev/null > "$state_dir/pending"
check grep -q '100.*old-sender.*receiver.*undelivered' "$state_dir/pending"
tmux new-window -d cat
tmux set -p -t %2 @agent receiver
ensure_agent_id %2 >/dev/null
"$B/tmux-ask" --retry --to receiver </dev/null > "$state_dir/retry"
check not_captured %2 lost-but-kept
check not_captured %2 legacy-body
check test -f "$legacy"
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 1
# Restoring the original ID, with a different label, makes redelivery safe.
tmux set -p -t %2 @agent restored-receiver
tmux set -p -t %2 @agent_id "$receiver_id"
"$B/tmux-ask" --retry --to restored-receiver </dev/null > "$state_dir/retry"
check captured %2 lost-but-kept
check test -f "$legacy"
rm -f "$legacy"
tmux set -p -t %2 @agent receiver
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 0
tmux set -p -t %0 @agent sender
# A killed lock owner leaves .sending recoverable, without stealing an
# active owner's file. Advisory locks keep their diagnostic PID file.
tmux set -p -t %0 @peers %2
tmux copy-mode -t %2
ask interrupted-body
tmux send-keys -t %2 -X cancel
TMUX_ASK_ENTER_DELAY=2 "$B/tmux-ask" --kick %2 </dev/null &
kicker=$!
has_sending() { [ -n "$(find "$Q" -name '*-2.sending')" ]; }
check wait_for has_sending
"$B/tmux-ask" --kick %2 </dev/null
check has_sending
owner="$(cat "$Q/.pane-2.lock")"
case "$owner" in ''|*[!0-9]*) echo 'FAIL: no lock owner PID'; exit 1 ;; esac
kill -KILL "$owner"
wait "$kicker" || true
check has_sending
# The owner's short-lived sleep child also inherited the descriptor.
sleep 2.1
# A stale retry PID file is harmless: the kernel lock is authoritative.
check test -f "$(dirname "$Q")/.retry.lock"
"$B/tmux-ask" --retry --to receiver </dev/null
check no_queued
check captured %2 interrupted-body
# A published .msg without any worker can likewise be restarted by retry.
tmux copy-mode -t %2
TMUX_ASK_TEST_FAIL_RUN=1 ask restart-worker-body
tmux send-keys -t %2 -X cancel
"$B/tmux-ask" --retry --to receiver </dev/null
check no_queued
check captured %2 restart-worker-body
# A reentrant attempt already holding SH must not upgrade if cleanup
# removes the migration marker. Bound this regression and kill its group.
marker="$(sessions_dir)/.ids-v1"
mv "$marker" "$marker.saved"
check agent_identity_lock shared perl -e '
  my $pid = fork(); die "fork: $!" unless defined $pid;
  if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec: $!"; }
  $SIG{ALRM} = sub { kill 9, -$pid; waitpid($pid, 0); exit 1; };
  alarm 5; waitpid($pid, 0); alarm 0; exit($? >> 8);
' env TMUX_ASK_IDENTITY_LOCKED=1 "$B/tmux-ask" --attempt %2 "$Q/absent.msg"
mv "$marker.saved" "$marker"
# Remove the marker inside an ordinary sender's shared-lock invocation,
# before it launches its synchronous --attempt child. The child must carry
# the flag along with the inherited descriptor, not try migration again.
mkdir "$state_dir/cleanup-bin"
cat > "$state_dir/cleanup-bin/tmux" <<WRAP
#!/usr/bin/env bash
if [ "\${TMUX_ASK_IDENTITY_LOCKED:-}" = 1 ] && [ -f '$marker' ]; then
  mv '$marker' '$marker.saved'
fi
exec '$real_tmux' "\$@"
WRAP
chmod +x "$state_dir/cleanup-bin/tmux"
check perl -e '
  my $pid = fork(); die "fork: $!" unless defined $pid;
  if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec: $!"; }
  $SIG{ALRM} = sub { kill 9, -$pid; waitpid($pid, 0); exit 1; };
  alarm 5; waitpid($pid, 0); alarm 0; exit($? >> 8);
' env PATH="$state_dir/cleanup-bin:$PATH" "$B/tmux-ask" --from sender --notice receiver inherited-lock-body
check test -f "$marker.saved"
check captured %2 inherited-lock-body
mv "$marker.saved" "$marker"
# Both endpoints gone: keep the body; client toast branch is captured by a
# wrapper around the real isolated-server tmux, without attaching a real UI.
tmux new-window -d cat
tmux kill-pane -t %0
tmux kill-pane -t %2
f="$Q/$(date +%s)-$$-2.msg"
printf '[request from sender to receiver via tmux-ask]\norphan-body\n' > "$f"
printf 'from_pane=%%0\nfrom_name=sender\nto_pane=%%2\nto_name=receiver\nkind=request\nqueued_at=1\n' > "${f%.msg}.meta"
mkdir "$state_dir/bin"
real_tmux="$(command -v tmux)"
cat > "$state_dir/bin/tmux" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = list-clients ]; then echo fake-client; exit 0; fi
if [ "\$1" = display-message ] && [ "\${2:-}" = -c ]; then printf '%s\\n' "\$*" >> '$state_dir/toasts'; exit 0; fi
exec '$real_tmux' "\$@"
WRAP
chmod +x "$state_dir/bin/tmux"
f="$(find "$Q" -name '*-2.msg' | head -n 1)"
if [ -n "$f" ]; then PATH="$state_dir/bin:$PATH" "$B/tmux-ask" --deliver %2 "$f" </dev/null; fi
check test "$(find "$Q" -name '*.undelivered' | wc -l | tr -d ' ')" = 1
check grep -q 'orphan-body' "$Q"/*.undelivered
check grep -q 'fake-client.*message\|fake-client.*kept' "$state_dir/toasts"
echo "Passed $count durable queue checks"
