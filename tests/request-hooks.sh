#!/usr/bin/env bash
# Turn hooks and one-slot reminders through actual sends and public reports.
# Claude 2.1.310 private hook probe confirmed queued prompts submit on processing.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-turn-hooks-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-turn-hooks.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir/state" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_IDLE_SECS=0
B="$state_dir/bin"; cp -R "$here/bin" "$B"
tmux -L "$sock" -f /dev/null new-session -d -x 180 -y 40 cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux split-window cat
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
tmux set -p -t %1 @parent %0
tmux set -p -t %0 @tracked 1
tmux set -p -t %1 @tracked 1
. "$B/lib.sh"
ensure_agent_ids
migrate_turn_state
receiver_id="$(pane_agent_id %1)"
record_set "$receiver_id" kind codex
record_set "$(pane_agent_id %0)" kind codex
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=$((fail+1)); fi; }
st() { tmux show -pqv -t %1 "$1"; }
reset_case() {
  for opt in state attention_since explicit_needs_you asking perm_since turn_began last_delivered owed_to owed_msg owed_at owed owed_settled owed_notified owed_asked codex_thread; do
    tmux set -pu -t %1 "@$opt"
  done
  tmux set -p -t %1 @state idle
  record_set "$receiver_id" kind codex
}
start() {
  /usr/bin/perl -CA -MJSON::PP -e 'print encode_json({prompt=>$ARGV[0], (@ARGV > 1 ? (session_id=>$ARGV[1]) : ())})' "$@" |
    "$B/tmux-agent-report" --pane %1 --turn-start
}
notify() {
  local payload
  payload="$(/usr/bin/perl -CA -MJSON::PP -e 'print encode_json({type=>"agent-turn-complete","thread-id"=>"turn-test","input-messages"=>[$ARGV[0]],"last-assistant-message"=>"finished"})' "$1")"
  "$B/tmux-agent-report" --agent-id "$receiver_id" --codex-notify "$payload"
}
body() { printf '[%s from sender to receiver via tmux-ask · %s]\nbody\n[end of %s from sender to receiver]' "$1" "$2" "$1"; }
send() { "$B/tmux-ask" --from sender "$@" receiver 'test delivery' >/dev/null; }
report() { "$B/tmux-agent-report" --pane %1 "$@" >/dev/null; }

reset_case
send
first="$(st @last_delivered)"
check 'request delivery starts Codex' test "$(st @state)" = working
check 'request fills one slot' test "$(st @owed_msg)" = "$first"
send
second="$(st @last_delivered)"
check 'new request has distinct token' test "$first" != "$second"
notify "$(body request "$first")"
check 'old notify cannot finish newer delivery' test "$(st @state)" = working
check 'old notify does not settle latest slot' test -z "$(st @owed_settled)"
notify "$(body request "$second")"
check 'matched notify finishes subagent' test "$(st @state)" = "done"
check 'matched request sends stop notice' test "$(st @owed_notified)" = 1
notice_count="$(tmux capture-pane -p -S - -t %0 | rg -c 'stopped without replying' || true)"
notify "$(body request "$second")"
check 'duplicate notify sends no extra reminder' test "$(tmux capture-pane -p -S - -t %0 | rg -c 'stopped without replying' || true)" = "$notice_count"
send --notice
notice="$(st @last_delivered)"
check 'notice delivery rearms stop reminder' test -z "$(st @owed_notified)"
notify "$(body notice "$notice")"
check 'settled obligation fires after notice nudge' test "$(st @owed_notified)" = 1

for kind in reply notice request; do
  reset_case; send
  if [ "$kind" = request ]; then
    "$B/tmux-ask" --from receiver sender answer >/dev/null
  else
    "$B/tmux-ask" --from receiver "--$kind" sender answer >/dev/null
  fi
  check "$kind clears obligation" test -z "$(st @owed)"
  send --reply
  if [ "$kind" = request ]; then
    check 'clarification answer refills obligation' test "$(st @owed)" = 1
    check 'clarification answer clears asked marker' test -z "$(st @owed_asked)"
  else
    check "$kind answer does not refill obligation" test -z "$(st @owed)"
  fi
done
reset_case; send
"$B/tmux-ask" --from receiver --reply sender answer >/dev/null
"$B/tmux-ask" --from receiver sender followup >/dev/null
send --reply
check 'followup after answering cannot refill slot' test -z "$(st @owed)"

for kind in reply notice; do
  reset_case; send "--$kind"
  check "$kind starts Codex" test "$(st @state)" = working
  check "$kind alone never fills slot" test -z "$(st @owed)"
done
reset_case
"$B/tmux-ask" --system-notice %1 'renamed peer' tmux-agents
check 'system notice starts Codex' test "$(st @state)" = working
check 'system notice never fills slot' test -z "$(st @owed)"

reset_case; send
report --codex-notify '{"type":"agent-turn-complete","thread-id":"turn-test"}'
check 'notify without inputs ends turn' test "$(st @state)" = "done"
check 'notify without inputs does not settle' test -z "$(st @owed_settled)"
reset_case; send
tmux set -pu -t %1 @last_delivered
notify "$(body request "$(st @owed_msg)")"
check 'empty latest token ends turn' test "$(st @state)" = "done"
check 'empty latest token never settles' test -z "$(st @owed_settled)"
reset_case; send
tmux set -pu -t %1 @owed_msg
notify "$(body request "$(st @last_delivered)")"
check 'empty owed token never settles' test -z "$(st @owed_settled)"

# Claude timestamps model explicit event ordering, not sleeps.
reset_case; record_set "$receiver_id" kind claude
send
check 'Claude delivery waits for prompt hook' test "$(st @state)" = idle
start "$(body request "$(st @owed_msg)")"
check 'Claude prompt starts turn' test "$(st @state)" = working
began="$(st @turn_began)"
report --perm on
report --perm off
check 'permission pause preserves turn beginning' test "$(st @turn_began)" = "$began"
agent_set_wait %1 message "$(date +%s)"
agent_set_wait %1 message ''
check 'message pause preserves turn beginning' test "$(st @turn_began)" = "$began"
report --needs-you question
report --tool-start </dev/null
check 'tool after needs-you preserves turn beginning' test "$(st @turn_began)" = "$began"
report progress
# Delivery and hook in the same second must settle inclusively.
tmux set -p -t %1 @owed_at "$began"
report --turn-end
check 'Claude inclusive timestamp settles' test "$(st @owed_settled)" = 1
check 'Claude end clears beginning' test -z "$(st @turn_began)"
report --tool-start </dev/null
check 'promptless tool resumes done pane' test "$(st @state)" = working
check 'promptless tool establishes beginning' test -n "$(st @turn_began)"
reset_case; record_set "$receiver_id" kind claude
send
report --turn-end
check 'promptless turn with no tool cannot settle' test -z "$(st @owed_settled)"
start user
send
tmux set -p -t %1 @owed_at "$(( $(st @turn_began) + 1 ))"
report --turn-end
check 'mid-turn Claude delivery cannot settle early' test -z "$(st @owed_settled)"

for header in old new; do
  reset_case; record_set "$receiver_id" kind claude
  msg="$(body notice m123456789abc)"
  [ "$header" = new ] || msg="${msg/ · m123456789abc/}"
  report --needs-you question
  start "$msg"
  check "$header notice header preserves attention" test "$(st @state)" = needs_you
  report --turn-end
  check "$header notice end preserves attention" test "$(st @state)" = needs_you
  start "$msg user draft"
  check "$header protocol followed by user text clears attention" test "$(st @state)" = working
done
reset_case
report --needs-you question
send --notice
notify "$(body notice "$(st @last_delivered)")"
check 'Codex notice turn preserves attention' test "$(st @state)" = needs_you
send --reply
check 'Codex non-notice delivery clears attention' test "$(st @state)" = working
report --turn-end
report progress
check 'progress reopens done' test "$(st @state)" = working
for flag in --waiting --local; do
  report --turn-end
  report "$flag" progress
  check "$flag is progress" test "$(st @state)" = working
  report --turn-end
  check "$flag does not hold turn open" test "$(st @state)" = "done"
done
report --local-done
check 'local-done no-op' test "$(st @state)" = "done"
send --request-id obsolete
check 'deprecated ID accepts request' test "$(st @state)" = working
send --request-id obsolete --reply
check 'deprecated ID accepts reply' test "$(st @state)" = working
# Legacy notify routing accepts either header even without launcher identity.
for header in old new; do
  reset_case
  record_set "$receiver_id" id ""
  msg="$(body notice m123456789abc)"
  [ "$header" = new ] || msg="${msg/ · m123456789abc/}"
  payload="$(/usr/bin/perl -CA -MJSON::PP -e 'print encode_json({type=>"agent-turn-complete","thread-id"=>"turn-test","input-messages"=>[$ARGV[0]]})' "$msg")"
  report --codex-notify "$payload"
  check "$header notify header routes receiver" test "$(st @codex_thread)" = turn-test
  check "$header notify header ends turn" test "$(st @state)" = "done"
done
reset_case; record_set "$receiver_id" kind claude
report --needs-you question
msg="$(body notice m123456789abc)"
start "<pasted_content id=\"wrapped\">$msg</pasted_content id=\"wrapped\">"
check 'wrapped notice preserves attention' test "$(st @state)" = needs_you

# After Claude clears context, resume uses the next prompt hook's session ID.
reset_case; record_set "$receiver_id" kind claude
old_session=11111111-2222-4333-8444-555555555555
new_session=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE
record_set "$receiver_id" id "$old_session"
report --needs-you question
start "$(body notice m123456789abc)" "$new_session"
check 'Claude new session updates stable record' test "$(record_get "$receiver_id" id)" = "$new_session"
check 'Claude session update keeps stable identity' test "$(pane_agent_id %1)" = "$receiver_id"
check 'Claude session update preserves notice attention' test "$(st @state)" = needs_you
start user "$new_session"
check 'Claude unchanged session is retained' test "$(record_get "$receiver_id" id)" = "$new_session"
check 'Claude unchanged session starts ordinary prompt' test "$(st @state)" = working
for invalid in '' not-a-uuid "${new_session}suffix" "prefix${new_session}" $'11111111-2222-4333-8444-555555555555\nid=bad'; do
  start user "$invalid"
  check "Claude invalid session is ignored: $invalid" test "$(record_get "$receiver_id" id)" = "$new_session"
done
start user
check 'Claude missing session retains resume ID' test "$(record_get "$receiver_id" id)" = "$new_session"
for other_kind in codex custom; do
  record_set "$receiver_id" kind "$other_kind"
  start user "$old_session"
  check "$other_kind hook cannot change resume ID" test "$(record_get "$receiver_id" id)" = "$new_session"
done
record_set "$receiver_id" id turn-test

# A notice preserves hook attention as well as explicit attention.
for agent in claude codex; do
  for resume in --tool-start --perm; do
    reset_case; record_set "$receiver_id" kind "$agent"
    report progress
    report --perm on
    permission="$(st @perm_since)"
    send --notice
    if [ "$agent" = claude ]; then start "$(body notice m123456789abc)"; fi
    check "$agent notice preserves permission hook" test "$(st @perm_since)" = "$permission"
    check "$agent notice exposes hook attention" test "$(st @state)" = needs_you
    if [ "$agent" = codex ]; then notify "$(body notice "$(st @last_delivered)")"; else report --turn-end; fi
    check "$agent notice end preserves permission hook" test "$(st @perm_since)" = "$permission"
    check "$agent notice end preserves attention" test "$(st @state)" = needs_you
    if [ "$resume" = --perm ]; then report --perm off; else report --tool-start </dev/null; fi
    check "$agent $resume resumes permission attention" test "$(st @state)" = working
    check "$agent $resume clears permission" test -z "$(st @perm_since)"
  done
done
reset_case; record_set "$receiver_id" kind claude
report --asking
start "$(body notice m123456789abc)"
report --turn-end
check 'notice retains question hook provenance' test "$(st @asking)" = 1
report --tool-end
check 'question answer after notice resumes work' test "$(st @state)" = working

# An attention pause still completes exactly one counted turn at Stop.
reset_case
report progress
before="$(st @turns)"; before="${before:-0}"
report --needs-you 'choose one'
report --turn-end
check 'attention survives completed turn' test "$(st @state)" = needs_you
check 'attention turn closes active counter' test -z "$(st @turn_active)"
check 'attention turn is counted' test "$(st @turns)" = "$((before + 1))"
report --turn-end
check 'repeated attention end counts once' test "$(st @turns)" = "$((before + 1))"

# Queued messages fill only once delivery succeeds, including legacy metadata.
reset_case
tmux copy-mode -t %1
send
check 'queued request does not start work' test "$(st @state)" = idle
check 'queued request does not fill slot' test -z "$(st @owed)"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
queued_file=""
for f in "$queue"/*.msg; do
  [ -f "$f" ] || continue
  if grep -q 'test delivery' "$f"; then queued_file="$f"; break; fi
done
check 'queued request has durable body' test -n "$queued_file"
token="$(sed -n 's/^message_id=//p' "${queued_file%.msg}.meta")"
check 'queue token is in pasted header' grep -Fq " · $token]" "$queued_file"
# Old request_id metadata is accepted and ignored; no reply matching remains.
printf 'request_id=roldignored\n' >> "${queued_file%.msg}.meta"
tmux send-keys -t %1 -X cancel
"$B/tmux-ask" --kick %1
for ((attempt=0; attempt<100; attempt++)); do
  if [ "$(st @owed_msg)" = "$token" ] && [ "$(st @state)" = working ]; then break; fi
  sleep .02
done
check 'delivered queued request starts work' test "$(st @state)" = working
check 'delivered queued request fills exact token' test "$(st @owed_msg)" = "$token"

reset_case
tmux set -pu -t %1 @parent
send
check 'top-level receiver has no owed slot' test -z "$(st @owed)"
notify "$(body request "$(st @last_delivered)")"
check 'top-level notify ends idle' test "$(st @state)" = idle
tmux set -p -t %1 @parent %0
reset_case
tmux set -p -t %0 @shell 1
turn_message_delivered %1 "$(pane_agent_id %0)" request m123456789abc
check 'shell sender cannot fill obligation' test -z "$(st @owed)"
tmux set -pu -t %0 @shell

# A tokenless legacy queued paste ends on notify but cannot settle a slot.
reset_case
turn_message_delivered %1 "$(pane_agent_id %0)" request ''
notify '[request from sender to receiver via tmux-ask]'
check 'legacy tokenless delivery can finish' test "$(st @state)" = "done"
check 'legacy tokenless delivery cannot settle' test -z "$(st @owed_settled)"
[ "$fail" = 0 ]
