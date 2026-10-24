#!/usr/bin/env bash
# Durable request IDs across queue, retry, rename, resume and completion contexts.
# REQUEST_LIFECYCLE_BIN optionally tests a frozen/old bin directory.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="${REQUEST_LIFECYCLE_BIN:-$here/bin}"
sock="tmux-request-lifecycle-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-request-lifecycle.XXXXXX")"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/stubs"
export TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0 TMUX_ASK_QUEUE_SECS=1800
export REQUEST_LIFECYCLE_LOG="$tmp/received"
mkdir -p "$tmp/stubs"
cat >"$tmp/stubs/claude" <<'STUB'
#!/bin/sh
stty -echo
printf 'REQUEST_LIFECYCLE_STUB\n'
printf '%s\n' "$@" >>"$REQUEST_LIFECYCLE_LOG"
exec cat >>"$REQUEST_LIFECYCLE_LOG"
STUB
cp "$tmp/stubs/claude" "$tmp/stubs/codex"
chmod +x "$tmp/stubs/claude" "$tmp/stubs/codex"
: >"$REQUEST_LIFECYCLE_LOG"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 60 -c "$tmp" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
tmux set -p -t %0 @tracked 1
tmux set -p -t %0 @state idle
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
ledger="$XDG_STATE_HOME/tmux-agents/${S##*/}/requests"
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=$((fail+1)); fi; }
# shellcheck disable=SC2329
contains() { grep -Fq -- "$2" "$1"; }
# shellcheck disable=SC2329
wait_for() { local i; for ((i=0; i<100; i++)); do if "$@"; then return 0; fi; sleep 0.1; done; return 1; }
# shellcheck disable=SC2329
ready() { tmux capture-pane -p -t "$1" | grep -q REQUEST_LIFECYCLE_STUB; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2==n {print $1}'; }
field() { awk -F= -v key="$2" '$1==key {print substr($0,length(key)+2)}' "$1"; }
opt() { tmux show -pqv -t "$1" "@$2"; }
# Locate a body by its unique marker and metadata identity, never file counts.
body_for() { local f; for f in "$queue"/*."$1"; do [ -f "$f" ] || continue; if grep -Fq -- "$2" "$f"; then printf '%s\n' "$f"; return 0; fi; done; return 1; }
# shellcheck disable=SC2329
body_exists() { body_for "$@" >/dev/null; }
ask() { "$B/tmux-ask" "$@"; }
"$B/tmux-spawn" claude --from main --exact --name receiver lifecycle-initial-request >"$tmp/spawn"
receiver="$(pane_of receiver)"
check 'spawn uses ready stub' wait_for ready "$receiver"
check 'initial prompt delivered to stub' wait_for contains "$REQUEST_LIFECYCLE_LOG" lifecycle-initial-request
rid="$(sed -n 's/.*--request-id \(r[0-9a-f]*\).*/\1/p' "$REQUEST_LIFECYCLE_LOG" | head -1)"
check 'spawn prompt has request identity' test -n "$rid"
# Old revisions have no ledger: preserve a useful red result without cascading errors.
if [ -z "$rid" ] || [ ! -f "$ledger/$rid.record" ]; then
  echo 'FAIL  initial request has no durable ledger record'
  exit 1
fi
receiver_id="$(pane_agent_id "$receiver")"
main_id="$(pane_agent_id %0)"
check 'spawn ledger identifies requester' test "$(field "$ledger/$rid.record" requester_id)" = "$main_id"
check 'spawn ledger identifies receiver' test "$(field "$ledger/$rid.record" receiver_id)" = "$receiver_id"
check 'spawn delivery recorded' test -n "$(field "$ledger/$rid.record" delivered_at)"
ask --from receiver --reply main --request-id "$rid" lifecycle-initial-answer >"$tmp/answer"
check 'initial spawn request answered' contains "$ledger/$rid.record" status=answered
check 'initial request completes helper' test "$(opt "$receiver" state)" = "done"
# Two same-pair queued requests carry distinct identities and cannot auto-resolve.
tmux copy-mode -t "$receiver"
ask --from main receiver lifecycle-queued-one >"$tmp/queued-one"
body1="$(body_for msg lifecycle-queued-one)"
r1="$(field "${body1%.msg}.meta" request_id)"
check 'copy-mode queues body' contains "$tmp/queued-one" 'queued request'
check 'queued body reply instruction carries exact ID' contains "$body1" "--request-id $r1"
check 'queued meta identifies receiver' contains "${body1%.msg}.meta" "to_id=$receiver_id"
check 'queued request is pending' contains "$ledger/$r1.record" status=pending
check 'queued request not delivered yet' test -z "$(field "$ledger/$r1.record" delivered_at)"
check 'queued request not overdue candidate' test -z "$(opt "$receiver" request_pending_since)"
ask --from main receiver lifecycle-queued-two >"$tmp/queued-two"
body2="$(body_for msg lifecycle-queued-two)"
r2="$(field "${body2%.msg}.meta" request_id)"
check 'same-pair request IDs differ' test "$r1" != "$r2"
if ask --from receiver --reply main lifecycle-ambiguous-answer >"$tmp/ambiguous" 2>&1; then
  check 'ambiguous implicit reply rejected' false
else
  check 'ambiguity explains request-id selection' contains "$tmp/ambiguous" '--request-id'
fi
# Preserve an exact saved message for resolved-retry regression below.
cp "$body1" "$tmp/saved-body"
cp "${body1%.msg}.meta" "$tmp/saved-meta"
tmux send-keys -t "$receiver" -X cancel
ask --retry --to receiver >"$tmp/retry"
check 'first request eventually delivered by identity' wait_for contains "$REQUEST_LIFECYCLE_LOG" lifecycle-queued-one
check 'second request eventually delivered by identity' wait_for contains "$REQUEST_LIFECYCLE_LOG" lifecycle-queued-two
check 'retry first request retains ledger ID' contains "$ledger/$r1.record" "request_id=$r1"
check 'retry first request sets delivery projection' test -n "$(opt "$receiver" request_pending_since)"
ask --from receiver --reply main --request-id "$r1" lifecycle-first-answer >"$tmp/first-answer"
check 'first exact reply resolves only first request' contains "$ledger/$r1.record" status=answered
check 'second request remains pending' contains "$ledger/$r2.record" status=pending
check 'same-peer aggregate wait remains' test "$(opt %0 awaiting)" = "$receiver_id"
check 'receiver remains working for second request' test "$(opt "$receiver" state)" = working
ask --from receiver --reply main lifecycle-unique-answer >"$tmp/unique-answer"
check 'unique implicit reply resolves remaining request' contains "$ledger/$r2.record" status=answered
check 'last reply clears aggregate wait' test -z "$(opt %0 awaiting)"
check 'last reply clears pending projection' test -z "$(opt "$receiver" request_pending_since)"
# Reinject a durable old copy, just as a crash/retry can retain one.
cp "$tmp/saved-meta" "$queue/1000000000-000001-${receiver#%}.meta"
cp "$tmp/saved-body" "$queue/1000000000-000001-${receiver#%}.undelivered"
ask --retry --to receiver >"$tmp/resolved-retry"
check 'retry cannot reopen answered request' contains "$ledger/$r1.record" status=answered
check 'resolved retry does not restart receiver' test "$(opt "$receiver" state)" = "done"
check 'resolved retry does not recreate wait' test -z "$(opt %0 awaiting)"
# Queue, close, bounce, resume: stable receiver identity and request survive.
tmux copy-mode -t "$receiver"
ask --from main receiver lifecycle-resume-request >"$tmp/queued-resume"
body3="$(body_for msg lifecycle-resume-request)"
r3="$(field "${body3%.msg}.meta" request_id)"
tmux copy-mode -t %0
"$B/tmux-dismiss" --from main receiver >"$tmp/dismiss"
check 'closed request retained as undelivered by identity' wait_for body_exists undelivered lifecycle-resume-request
saved="$(body_for undelivered lifecycle-resume-request)"
check 'bounce preserves exact request ID metadata' contains "${saved%.undelivered}.meta" "request_id=$r3"
check 'closure retains pending ledger' contains "$ledger/$r3.record" status=pending
"$B/tmux-spawn" --from main --resume receiver >"$tmp/resume"
receiver="$(pane_of receiver)"
check 'resumed receiver stub ready' wait_for ready "$receiver"
check 'resume preserves receiver stable ID' test "$(pane_agent_id "$receiver")" = "$receiver_id"
check 'resume delivers exact saved request' wait_for contains "$REQUEST_LIFECYCLE_LOG" lifecycle-resume-request
check 'resume pending request remains active' test "$(opt "$receiver" state)" = working
"$B/tmux-rename" --from main receiver renamed --exact >"$tmp/rename"
check 'rename keeps stable receiver ID' test "$(pane_agent_id "$receiver")" = "$receiver_id"
ask --from renamed --reply main --request-id "$r3" lifecycle-renamed-answer >"$tmp/renamed-answer"
check 'renamed receiver answers original stable request' contains "$ledger/$r3.record" status=answered
check 'renamed receiver completes after final answer' test "$(opt "$receiver" state)" = "done"
check 'request context cleared after completion' test ! -f "$ledger/$receiver_id.context"
# Explicit local work and background waits remain after an interrupting request.
"$B/tmux-agent-report" --from renamed --local lifecycle-local-work >"$tmp/local-work"
"$B/tmux-agent-report" --from renamed --waiting lifecycle-background >"$tmp/background"
ask --from main renamed lifecycle-context-request >"$tmp/context-request"
# Locate via ledger identity; only this receiver's pending context request remains.
r4="$(/usr/bin/perl "$B/tmux-request-state" incoming "$receiver")"
check 'persistent context records local work' contains "$ledger/$receiver_id.context" local_work=1
"$B/tmux-dismiss" --from main renamed >"$tmp/context-dismiss"
"$B/tmux-spawn" --from main --resume renamed >"$tmp/context-resume"
receiver="$(pane_of renamed)"
check 'context resume stub ready' wait_for ready "$receiver"
check 'local work context survives resume' contains "$ledger/$receiver_id.context" local_work=1
check 'background wait survives resume' test "$(opt "$receiver" waiting_on)" = lifecycle-background
ask --from renamed --reply main --request-id "$r4" lifecycle-context-answer >"$tmp/context-answer"
check 'reply preserves explicit local work' test "$(opt "$receiver" state)" = working
check 'reply preserves background wait' test "$(opt "$receiver" waiting_on)" = lifecycle-background
"$B/tmux-agent-report" --from renamed --local-done >"$tmp/local-done"
check 'local-done still preserves background wait' test "$(opt "$receiver" state)" = working
"$B/tmux-agent-report" --from renamed lifecycle-background-finished >"$tmp/background-finished"
"$B/tmux-agent-report" --from renamed --turn-end >"$tmp/turn-end"
check 'completion after background wait clears' test "$(opt "$receiver" state)" = "done"
check 'all completed requests clear projection' test -z "$(opt "$receiver" request_pending_since)"
# Deterministic completion/create interleaving: a new request arrives after the
# completion query returns, before the old caller commits its terminal state.
/usr/bin/perl "$B/tmux-request-state" local-done "$receiver"
race_id=r000000000099
request_state() {
  /usr/bin/perl "$B/tmux-request-state" "$@"
  if [ "$1" = completion ] || [ "$1" = finish ]; then
    /usr/bin/perl "$B/tmux-request-state" create "$race_id" "$main_id" "$receiver_id"
  fi
}
request_finish "$receiver" || true
check 'interleaved request remains pending' contains "$ledger/$race_id.record" status=pending
check 'completion cannot overwrite newer request state' test "$(opt "$receiver" state)" = working
echo "$((count-fail))/$count passed"
[ "$fail" -eq 0 ]
