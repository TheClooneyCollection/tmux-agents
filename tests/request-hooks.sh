#!/usr/bin/env bash
# Request hook regression: complete protocol classification, explicit local
# completion, CLI validation and top-level attention. Uses only a private socket.
# REQUEST_HOOKS_REPORT can select a saved pre-fix report script for a red run.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-request-hooks-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-request-hooks.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir/state" TMUX_ASK_ENTER_DELAY=0
B="$state_dir/bin"
cp -R "$here/bin" "$B"
if [ -n "${REQUEST_HOOKS_REPORT:-}" ]; then cp "$REQUEST_HOOKS_REPORT" "$B/tmux-agent-report"; fi
tmux -L "$sock" -f /dev/null new-session -d -x 120 -y 30 cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux split-window cat
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"
receiver_id="$(pane_agent_id %1)"
sender_id="$(pane_agent_id %0)"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=$((fail+1)); fi; }
st() { tmux show -pqv -t %1 "$1"; }
reset_case() {
  rm -rf "$XDG_STATE_HOME/tmux-agents/$sock/requests"
  for opt in state attention_since waiting_on awaiting request_local_work request_local_done request_progress_at request_pending_since request_notify_digest codex_thread; do
    tmux set -pu -t %1 "@$opt" 2>/dev/null || true
  done
  tmux set -p -t %1 @tracked 1
  tmux set -p -t %1 @state idle
}
start() {
  /usr/bin/perl -MJSON::PP -e 'print encode_json({prompt=>$ARGV[0]})' "$1" |
    "$B/tmux-agent-report" --pane %1 --turn-start
}
notify() {
  local payload
  payload="$(/usr/bin/perl -MJSON::PP -e 'print encode_json({type=>"agent-turn-complete","thread-id"=>"request-hooks-thread","input-messages"=>[$ARGV[0]],"last-assistant-message"=>"finished"})' "$1")"
  "$B/tmux-agent-report" --agent-id "$receiver_id" --codex-notify "$payload"
}
# Full protocol messages preserve explicit background waits; any outside draft
# is a local user instruction. Exercise every kind, bare and Claude-wrapped.
for kind in request reply notice; do
  body="$(printf '[%s from sender to receiver via tmux-ask]\nbody\n[end of %s from sender to receiver]' "$kind" "$kind")"
  for wrapper in bare wrapped; do
    message="$body"
    if [ "$wrapper" = wrapped ]; then message="<pasted_content id=\"abc\">$body</pasted_content id=\"abc\">"; fi
    reset_case
    "$B/tmux-agent-report" --pane %1 --waiting build >/dev/null
    start "$message"
    check "$kind $wrapper is protocol" test -z "$(st @request_local_work)"
    check "$kind $wrapper preserves background wait" test "$(st @waiting_on)" = build
    reset_case
    start "$message user draft"
    check "$kind $wrapper trailing draft is local" test "$(st @request_local_work)" = 1
    reset_case
    notify "$message"
    check "notify $kind $wrapper is protocol" test -z "$(st @request_local_work)"
    reset_case
    notify "$message user draft"
    check "notify $kind $wrapper draft is local" test "$(st @request_local_work)" = 1
  done
done
reset_case
start '[request from sender to receiver via tmux-ask] incomplete'
check 'incomplete protocol is local' test "$(st @request_local_work)" = 1
reset_case
start "user draft $body"
check 'leading draft is local' test "$(st @request_local_work)" = 1
reset_case
start "$(printf '%s\n%s' "$body" "$body")"
check 'multiple complete notices are protocol' test -z "$(st @request_local_work)"

reset_case
"$B/tmux-agent-report" --pane %1 --local 'direct user task' >/dev/null
"$B/tmux-agent-report" --pane %1 --local-done
notify 'direct user task'
check 'notify does not reopen explicitly completed local work' test -z "$(st @request_local_work)"
check 'completed direct user task stays idle' test "$(st @state)" = idle
check 'notify consumes local-done marker' test -z "$(st @request_local_done)"
notify 'direct user task'
check 'duplicate notify keeps completed local work idle' test "$(st @state)" = idle
check 'duplicate notify does not recreate local marker' test -z "$(st @request_local_work)"
"$B/tmux-agent-report" --pane %1 --local 'direct user task' >/dev/null
notify 'direct user task'
check 'explicit local starts a new identical task' test "$(st @state)" = needs_you
notify 'next direct user task'
check 'next direct user task starts local work' test "$(st @request_local_work)" = 1

reset_case
request_state create r0123456789ab "$sender_id" "$receiver_id"
"$B/tmux-agent-report" --pane %1 --turn-end </dev/null
check 'top-level unanswered request needs user' test "$(st @state)" = needs_you
"$B/tmux-agent-report" --pane %1 --waiting build >/dev/null
"$B/tmux-agent-report" --pane %1 --turn-end </dev/null
check 'top-level request with background wait stays working' test "$(st @state)" = working
"$B/tmux-agent-report" --pane %1 'build complete' >/dev/null
check 'ordinary progress clears background wait' test -z "$(st @waiting_on)"
check 'request progress does not create local work' test -z "$(st @request_local_work)"

# Invalid calls must fail before changing local or wait markers.
reject() {
  reset_case
  tmux set -p -t %1 @request_local_work 1
  tmux set -p -t %1 @waiting_on preserved
  if "$B/tmux-agent-report" --pane %1 "$@" >"$state_dir/rejected.log" 2>&1; then
    echo "FAIL invalid command accepted: $*"; fail=$((fail+1))
  else echo "ok invalid command rejected: $*"; fi
  check "invalid command preserves local: $*" test "$(st @request_local_work)" = 1
  check "invalid command preserves wait: $*" test "$(st @waiting_on)" = preserved
}
reject --local-done extra
reject --local --local-done
reject --local-done --waiting text
reject --local
reject --local --turn-end text
reject --local-done --save-work
reset_case
"$B/tmux-agent-report" --pane %1 --local 'parallel completion' >/dev/null
"$B/tmux-agent-report" --pane %1 --local-done
notify 'parallel completion' & first_notify=$!
notify 'parallel completion' & second_notify=$!
wait "$first_notify"
wait "$second_notify"
check 'concurrent duplicate notify consumes receipt once' test -z "$(st @request_local_done)"
check 'concurrent duplicate notify keeps task complete' test "$(st @state)" = idle
check 'concurrent duplicate notify never recreates local work' test -z "$(st @request_local_work)"

# Inject a real incoming request after turn-end has read its empty request
# set, before its terminal state commit. The body of the hook is unmodified.
reset_case
export REQUEST_RACE_FROM="$sender_id" REQUEST_RACE_TO="$receiver_id" REQUEST_RACE_MARKER="$state_dir/injected"
cat >>"$B/lib.sh" <<'RACE'
request_state() {
  local output core
  core="$(dirname "${BASH_SOURCE[0]}")/tmux-request-state"
  output="$(/usr/bin/perl "$core" "$@")" || return $?
  if [ "$1" = incoming ] && [ ! -f "$REQUEST_RACE_MARKER" ]; then
    : >"$REQUEST_RACE_MARKER"
    /usr/bin/perl "$core" create r0123456789ac "$REQUEST_RACE_FROM" "$REQUEST_RACE_TO"
  fi
  printf '%s\n' "$output"
}
RACE
"$B/tmux-agent-report" --pane %1 --turn-end </dev/null
check 'late request retains pending identity' test "$(request_state incoming %1)" = r0123456789ac
check 'old turn-end cannot idle a newly received request' test "$(st @state)" = working
printf '%s failures\n' "$fail"
[ "$fail" -eq 0 ]
