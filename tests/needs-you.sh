#!/usr/bin/env bash
# Regression tests for "needs you": normal workflows must not flag a sub
# agent as needing the user, and a few real cases must. Drives the real
# scripts in an isolated tmux server (never the user's), with `cat` panes
# standing in for agents and Claude hooks / Codex notify simulated by
# calling tmux-agent-report directly.
#
#   tests/needs-you.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-test-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"

unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0

tmux -L "$sock" -f /dev/null new-session -d -x 120 -y 30 cat
# Never let this reach the user's live server: the test server must be up,
# on a real socket that isn't the default one.
tmux -L "$sock" has-session 2>/dev/null || { echo "ABORT: test server not up"; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT

tmux set-option -g default-shell /bin/sh
# Use the synchronous chip format; this suite tests state, not animation.
tmux set-option -g @tmux_agents_chip_fps 1
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"

# boss (%0) and its sub agent kid (%1), connected like tmux-spawn does.
tmux split-window cat
TMUX_PANE=%0 "$B/tmux-connect" %1 --as boss <<< kid >/dev/null
tmux set -p -t %1 @parent %0

fail=0
st() { tmux show -pqv -t "$1" "$2"; }
reset() {
  # Independent cases share a server, never obligations. Remove only this
  # suite's socket ledger beneath its own temporary state directory.
  rm -rf "$state_dir/tmux-agents/$sock/requests"
  for p in %0 %1; do
    for o in @explicit_needs_you @attention_since @waiting_on @awaiting @activity @codex_thread @request_local_work @request_local_done @request_progress_at @request_pending_since; do tmux set -pu -t "$p" "$o" 2>/dev/null; done
  done
  tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state working
}
# Claude hooks for kid; $1 is the prompt that started the turn.
turn_start() { printf '{"prompt":%s}' "$(printf '%s' "$1" | /usr/bin/perl -MJSON::PP -0777 -ne 'print JSON::PP->new->encode($_)')" | "$B/tmux-agent-report" --pane %1 --turn-start; }
turn_end() { "$B/tmux-agent-report" --pane %1 --turn-end </dev/null; }
notify() {  # thread, last assistant message, input message
  "$B/tmux-agent-report" --codex-notify "$(/usr/bin/perl -MJSON::PP -e 'print JSON::PP->new->encode({type=>"agent-turn-complete","thread-id"=>$ARGV[0],"last-assistant-message"=>$ARGV[1],"input-messages"=>[$ARGV[2]]})' "$@")"
}
ask() { local from="$1"; shift; TMUX_PANE="$from" "$B/tmux-ask" "$@" >/dev/null; }
expect() {  # name, wanted kid state
  local got
  got="$(st %1 @state)"
  if [ "$got" = "$2" ]; then echo "ok    $1 ($got)"; else echo "FAIL  $1: kid is $got, wanted $2"; fail=1; fi
}

check() {
  local label="$1"; shift
  if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi
}

echo "Explicit user attention through the public CLI"
for role in top-level sub-agent; do
  reset
  if [ "$role" = top-level ]; then tmux set -pu -t %1 @parent; else tmux set -p -t %1 @parent %0; fi
  if [ "$role" = top-level ]; then
    tmux set -g status on
    tmux set -g 'status-format[0]' original-status
    tmux set -gu @tmux_agents_main_format
    check "top-level fixture starts without chip layout" test "$(tmux show -gv status)" = on
  fi
  "$B/tmux-agent-report" --from kid --needs-you "choose deployment region" >/dev/null
  if [ "$role" = top-level ]; then
    check "top-level explicit attention enables chip layout" test "$(tmux show -gv status)" = 2
    check "top-level chip retains original status" test "$(tmux show -gv 'status-format[1]')" = original-status
    check "top-level chip format renders chip" test "$(tmux show -gv 'status-format[0]')" = "#($B/tmux-agents --chip)"
  fi
  expect "$role explicitly needs user before turn end" needs_you
  check "$role reason is activity" test "$(st %1 @activity)" = "choose deployment region"
  check "$role has attention time" test -n "$(st %1 @attention_since)"
  tmux set -p -t %1 @attention_since 123
  "$B/tmux-agent-report" --from kid --needs-you "choose deployment region" >/dev/null
  turn_end
  expect "$role explicit attention survives turn end" needs_you
  check "$role retains reason" test "$(st %1 @activity)" = "choose deployment region"
  check "$role repeated report retains attention age" test "$(st %1 @attention_since)" = 123
  FZF_PROMPT='agents · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' >"$state_dir/explicit-list"
  check "$role included in default list" grep -q '^%1 ' "$state_dir/explicit-list"
  check "$role pinned in attention section" grep -q '▸ needs you' "$state_dir/explicit-list"
  "$B/tmux-agents" --preview-info %1 >"$state_dir/explicit-preview"
  check "$role preview includes full reason" grep -q 'choose deployment region' "$state_dir/explicit-preview"
  "$B/tmux-agents" --chip >"$state_dir/explicit-chip"
  check "$role chip shows user attention" grep -q 'NEEDS YOU' "$state_dir/explicit-chip"
  "$B/tmux-agent-report" --from kid "resuming deployment" >/dev/null
  expect "$role progress clears attention" working
  check "$role progress clears attention time" test -z "$(st %1 @attention_since)"
  "$B/tmux-agent-report" --from kid --needs-you "choose again" >/dev/null
  turn_start "use London"
  expect "$role user turn start clears attention" working
  check "$role turn start clears explicit marker" test -z "$(st %1 @explicit_needs_you)"
  "$B/tmux-agent-report" --from kid --needs-you "another choice" >/dev/null
  turn_start "$(notice_body boss fyi kid)"
  check "$role notice turn start clears explicit marker" test -z "$(st %1 @explicit_needs_you)"
  "$B/tmux-agent-report" --from kid --needs-you "another choice" >/dev/null
  ask %0 kid "new work clears explicit attention"
  expect "$role new request resumes work" working
  check "$role new request clears explicit marker" test -z "$(st %1 @explicit_needs_you)"
done
reset
tmux set -pu -t %1 @parent
ask %0 kid "deployment request must remain pending"
request_dir="$(dirname "$(sessions_dir)")/requests"
pending_record=""
for record in "$request_dir"/r*.record; do
  [ -f "$record" ] || continue
  if grep -qx 'status=pending' "$record"; then pending_record="$record"; fi
done
check "request fixture has a ledger record" test -n "$pending_record"
"$B/tmux-agent-report" --from kid --needs-you "approve deployment" >/dev/null
turn_end
check "explicit attention preserves pending request identity" grep -qx 'status=pending' "$pending_record"
tmux set -p -t %1 @codex_thread explicit-thread
notify explicit-thread "awaiting approval" "deploy this"
expect "Codex notify preserves explicit attention" needs_you
check "Codex notify preserves reason" test "$(st %1 @activity)" = "approve deployment"
check "Codex notify leaves request pending" grep -qx 'status=pending' "$pending_record"
"$B/tmux-agent-report" --from kid "approved, deploying" >/dev/null
check "progress leaves request pending" grep -qx 'status=pending' "$pending_record"
# Ordinary top-level rows stay excluded once their attention clears.
FZF_PROMPT='agents · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' >"$state_dir/ordinary-list"
if grep -q '^%1 ' "$state_dir/ordinary-list"; then echo 'FAIL ordinary top-level included'; fail=1; fi
reset
tmux set -pu -t %1 @tracked
if "$B/tmux-agent-report" --from kid --needs-you "untracked question" >"$state_dir/invalid" 2>&1; then echo 'FAIL untracked report accepted'; fail=1; fi
tmux set -p -t %1 @state needs_you
FZF_PROMPT='agents · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' >"$state_dir/untracked-list"
if grep -q '^%1 ' "$state_dir/untracked-list"; then echo 'FAIL untracked top-level attention included'; fail=1; fi
"$B/tmux-agents" --chip >"$state_dir/untracked-chip"
if grep -q 'NEEDS YOU' "$state_dir/untracked-chip"; then echo 'FAIL untracked chip attention'; fail=1; fi
reset
for args in missing empty waiting local "done"; do
  case "$args" in
    missing) set -- --needs-you ;;
    empty) set -- --needs-you '' ;;
    waiting) set -- --needs-you --waiting reason ;;
    local) set -- --local --needs-you reason ;;
    done) set -- --local-done --needs-you reason ;;
  esac
  if "$B/tmux-agent-report" --from kid "$@" >"$state_dir/invalid" 2>&1; then echo "FAIL invalid needs-you arguments: $args"; fail=1; else echo "ok    rejected needs-you arguments: $args"; fi
done
tmux set -p -t %1 @parent %0
# Existing accounting cases start from a fresh turn counter.
for o in @turns @turn_start @last_turn @worked; do tmux set -pu -t %1 "$o"; done

echo "Top-level turn ends and wakeups"
reset
tmux set -pu -t %1 @parent
turn_start "user task"
tmux set -p -t %1 @attention_since 1
check "user prompt starts local work for its turn" test "$(st %1 @request_local_work)" = 1
turn_end
expect "top-level with nothing pending goes idle" idle
check "the prompt's local work ends with its turn" test -z "$(st %1 @request_local_work)"
check "top-level clears old attention" test -z "$(st %1 @attention_since)"
check "idle completes the worked-time turn" test "$(st %1 @turns)" = 1
check "idle stops active work clock" test -z "$(st %1 @turn_start)"
turn_end
check "duplicate idle turn end does not count twice" test "$(st %1 @turns)" = 1
turn_start "next user prompt"
expect "turn-start wakes idle top-level" working
turn_end
"$B/tmux-agent-report" --pane %1 "resumed top-level work" >/dev/null
expect "progress report wakes idle top-level" working
turn_end
ask %0 kid "new request"
expect "incoming request wakes idle top-level" working
turn_end
expect "top-level unanswered incoming request needs the user" needs_you
turn_start "delegate work to boss"
ask %1 boss "pending reply"
turn_end
expect "top-level awaiting live agent stays working" working
check "top-level shows awaited agent" test "$(st %1 @activity)" = "waiting for boss"
check "top-level waiting has no attention marker" test -z "$(st %1 @attention_since)"
ask %0 --reply kid "answer"
turn_end
expect "outgoing answer leaves incoming and local work unfinished" needs_you
ask %1 --reply boss "incoming task complete"
turn_end
expect "top-level goes idle after all requests finish" idle
# Only --local promises a --local-done: that work outlives its turns.
"$B/tmux-agent-report" --pane %1 --local "long user task" >/dev/null
turn_end
expect "explicit local work keeps needing the user at turn end" needs_you
ask %0 kid "side question"
ask %1 --reply boss "side answer"
turn_end
expect "answering a request preserves explicit local work" needs_you
"$B/tmux-agent-report" --pane %1 --local-done
turn_end
expect "top-level goes idle after explicit local work finishes" idle
# Ownership, including member ownership, keeps the existing needs-you rule.
tmux set -p -t %1 @parent %0
reset
turn_end
expect "sub agent still needs you with nothing pending" needs_you
tmux set -p -t %1 @member 1
reset
turn_end
expect "member still needs you with nothing pending" needs_you
tmux set -pu -t %1 @member

echo "Claude pasted rename notices preserve task state"
# Claude 2.1.301 wraps bracketed-paste input, including rename notices.
rename_notice="$(notice_body tmux-rename 'boss is now renamed-boss' kid)"
wrapped_notice="$(printf '\n\n<pasted_content id="d21a">\n%s\n</pasted_content id="d21a">\n' "$rename_notice")"
for initial in idle "done" needs_you; do
  reset
  tmux set -p -t %1 @state "$initial"
  if [ "$initial" = needs_you ]; then tmux set -p -t %1 @attention_since 123; fi
  turn_start "$wrapped_notice"
  expect "wrapped rename notice keeps $initial at turn start" "$initial"
  turn_end
  expect "wrapped rename notice keeps $initial at turn end" "$initial"
  if [ "$initial" = needs_you ]; then
    check "notice preserves existing attention timestamp" test "$(st %1 @attention_since)" = 123
  else
    check "notice adds no attention" test -z "$(st %1 @attention_since)"
  fi
done
reset
"$B/tmux-agent-report" --pane %1 --waiting "CI run" >/dev/null
turn_start "$wrapped_notice"; turn_end
expect "wrapped rename notice preserves background wait" working
check "wrapped notice keeps wait reason" test "$(st %1 @waiting_on)" = "CI run"
for mixed in "please review this $wrapped_notice" "$wrapped_notice please review this"; do
  reset
  tmux set -p -t %1 @state idle
  turn_start "$mixed"; turn_end
  expect "user text outside pasted notice starts work" needs_you
done
reset
tmux set -p -t %1 @state idle
turn_start "$(printf '<pasted_content id="d21a">\n%s\nplease review this\n</pasted_content id="d21a">' "$rename_notice")"
turn_end
expect "user text inside pasted notice starts work" needs_you

echo "Normal workflows: never needs you"

reset
tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state idle
turn_end
expect "idle without a task stays idle at turn end" idle
"$B/tmux-agent-report" --pane %1 "starting work" >/dev/null
expect "progress report starts idle agent working" working

reset
tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state idle
ask %0 kid "first task"
expect "first request starts idle agent working" working

reset
ask %0 kid "do x"; turn_start "$(request_body boss 'do x' kid)"
ask %1 --reply boss "done"; turn_end
expect "replies to its parent, then ends its turn" "done"

reset
ask %0 kid "do z"; turn_start "$(request_body boss 'do z' kid)"
ask %1 --reply boss "delivered abc123"
"$B/tmux-agent-report" --pane %1 "abc123 delivered, all green" >/dev/null; turn_end
expect "replies, then reports progress, then ends its turn" "done"

turn_start "$(notice_body boss fyi kid)"; turn_end
expect "done, then gets a notice" "done"
[ -z "$(st %0 @awaiting)" ] || { echo "FAIL  a notice made boss wait on kid"; fail=1; }

reset
tmux new-window -d cat; gk="$(tmux list-panes -a -F '#{pane_id}' | tail -1)"
tmux set -p -t "$gk" @agent grandkid; tmux set -p -t "$gk" @parent %1; tmux set -p -t "$gk" @tracked 1; tmux set -p -t "$gk" @state working
turn_end
expect "waits for its own sub agent" working
tmux kill-pane -t "$gk"

reset
ask %1 boss "question for you"; turn_end
expect "waits for the reply to a request it sent" working

reset
ask %1 --notice boss "progress update"; turn_end
expect "notice to its parent, then ends its turn" working
[ "$(st %1 @waiting_on)" = "boss (after a notice)" ] || { echo "FAIL  missing parent notice wait marker"; fail=1; }
[ "$(st %1 @activity)" = "waiting for boss (after a notice)" ] || { echo "FAIL  missing parent notice wait activity"; fail=1; }
[ -z "$(st %1 @awaiting)" ] || { echo "FAIL  sending a notice created a reply obligation"; fail=1; }

ask %0 --notice kid "acknowledged"
turn_start "$(notice_body boss acknowledged kid)"; turn_end
expect "parent notice wait survives an incoming notice" working

ask %1 --reply boss "done"; turn_end
expect "reply after parent notice stays done" "done"
ask %1 --notice boss "one last FYI"; turn_end
expect "done agent sends parent notice and stays done" "done"

reset
# The parent's display name can change; ownership is its pane ID.
tmux set -p -t %0 @agent renamed-boss
ask %1 --any --notice renamed-boss "FYI"; turn_end
expect "notice recognizes parent by pane ID after rename" working
[ "$(st %1 @waiting_on)" = "renamed-boss (after a notice)" ] || { echo "FAIL  notice wait did not use current parent name"; fail=1; }
tmux set -p -t %0 @agent boss

reset
"$B/tmux-agent-report" --pane %1 --waiting "CI run" >/dev/null; turn_end
expect "reported --waiting for background work" working

reset
"$B/tmux-agent-report" --pane %1 --waiting "CI run" >/dev/null
turn_start "$(notice_body boss fyi kid)"; turn_end
expect "waiting on background work, then gets a notice" working
[ "$(st %1 @waiting_on)" = "CI run" ] || { echo "FAIL  the notice cleared what kid waits on"; fail=1; }

reset
ask %0 kid "do y"
ask %0 --notice kid "also, fyi"
expect "working, then gets a notice" working

reset
tmux set -p -t %1 @codex_thread main-thread
notify title-thread '{"title":"Do y"}' "$(request_body boss 'do y' kid)"
expect "Codex names its session (title thread)" working
[ "$(st %1 @codex_thread)" = main-thread ] || { echo "FAIL  the title thread replaced @codex_thread"; fail=1; }

reset
tmux set -p -t %1 @codex_thread main-thread; tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state "done"
notify main-thread "done, standing by" "$(reply_body boss 'answer to earlier request' kid)"
expect "Codex, done, another turn end" "done"

reset
tmux set -p -t %1 @codex_thread main-thread; tmux set -p -t %1 @state "done"
notify main-thread "still working on the user task" "please review this directly"
expect "Codex direct user input reopens done and needs the user" needs_you
check "Codex direct input completes with its turn" test -z "$(st %1 @request_local_work)"

echo "Real cases: needs you"

reset
ask %1 --notice boss "progress update"; turn_end
ask %0 kid "next task"
[ -z "$(st %1 @waiting_on)" ] || { echo "FAIL  new request retained parent notice wait"; fail=1; }
# No turn_start hook: Codex must also stop waiting on a new request.
turn_end
expect "new request clears parent notice wait without a turn-start hook" needs_you

reset
ask %1 --notice boss "progress update"
"$B/tmux-agent-report" --pane %1 "resumed work" >/dev/null
[ -z "$(st %1 @waiting_on)" ] || { echo "FAIL  progress report retained parent notice wait"; fail=1; }
turn_end
expect "progress report clears parent notice wait" needs_you

reset
tmux new-window -d cat; other="$(tmux list-panes -a -F '#{pane_id}' | tail -1)"
tmux set -p -t "$other" @agent colleague
ask %1 --any --notice colleague "FYI"
[ -z "$(st %1 @waiting_on)" ] || { echo "FAIL  nonparent notice created a wait marker"; fail=1; }
turn_end
expect "notice to a nonparent does not imply waiting" needs_you
tmux kill-pane -t "$other"

reset
"$B/tmux-agent-report" --pane %1 --waiting "CI run" >/dev/null
ask %0 kid "next task"; turn_end
expect "new request preserves background wait without a turn-start hook" working
check "new request retains explicit background reason" test "$(st %1 @waiting_on)" = "CI run"

reset
turn_end
expect "ends its turn without replying or waiting" needs_you

reset
"$B/tmux-agent-report" --pane %1 --waiting "CI run" >/dev/null
ask %0 kid "new task"
turn_start "$(request_body boss 'new task' kid)"; turn_end
expect "a protocol request turn preserves background work" working
check "request turn retains explicit background reason" test "$(st %1 @waiting_on)" = "CI run"

reset
tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state "done"
ask %0 kid "no reply needed, don't restart"
turn_start "$(request_body boss 'no reply needed' kid)"; turn_end
expect "a request (not a notice) answered only locally" needs_you

# An owned plain shell is not outstanding agent work.
reset
shell_child="$(tmux new-window -d -P -F '#{pane_id}' cat)"
tmux set -p -t "$shell_child" @shell 1
tmux set -p -t "$shell_child" @parent %1
tmux set -p -t "$shell_child" @agent shell-test-1
turn_end
expect "owned shell does not keep a finished turn waiting" needs_you
tmux kill-pane -t "$shell_child"

# A rename changes displayed waiting labels, never the stored obligation.
reset
kid_id="$(pane_agent_id %1)"
record_set "$kid_id" name kid
record_set "$kid_id" id main-thread
ask %0 kid "identity request"
"$B/tmux-rename" --from boss kid renamed-kid --exact >/dev/null
"$B/tmux-agent-report" --pane %0 --turn-end </dev/null
[ "$(st %0 @awaiting)" = "$kid_id" ] || { echo 'FAIL awaiting ID changed on rename'; fail=1; }
case "$(st %0 @activity)" in *renamed-kid*) echo 'ok    waiting activity resolves current label' ;; *) echo 'FAIL waiting activity uses stale label'; fail=1 ;; esac
ask %1 --reply boss "identity reply"
[ -z "$(st %0 @awaiting)" ] || { echo 'FAIL renamed reply left an obligation'; fail=1; }
notify main-thread "done" "$(request_body boss 'old header' kid)"
[ "$(record_get "$kid_id" id)" = main-thread ] || { echo 'FAIL notify did not retain identity record'; fail=1; }
# A late notify from a closed conversation cannot bind a reused label.
tmux new-window -d cat
new_pane="$(tmux list-panes -a -F '#{pane_id}' | tail -n 1)"
tmux set -p -t "$new_pane" @agent kid
ensure_agent_id "$new_pane" >/dev/null
tmux kill-pane -t %1
notify main-thread "late completion" "$(request_body boss 'old header' kid)"
[ -z "$(st "$new_pane" @codex_thread)" ] || { echo 'FAIL late notify bound to reused label'; fail=1; }

# A verified current identity may resume the closed thread; its unfinished
# work still needs attention when the accepted completion arrives.
record_set "$kid_id" closed 123
tmux set -p -t "$new_pane" @parent %0
"$B/tmux-agent-report" --from kid 'resumed work' >/dev/null
"$B/tmux-agent-report" --agent-id "$(pane_agent_id "$new_pane")" --codex-notify '{"type":"agent-turn-complete","thread-id":"main-thread","input-messages":["continue work"],"last-assistant-message":"need input"}'
check 'resumed closed thread binds current identity' test "$(st "$new_pane" @codex_thread)" = main-thread
check 'resumed unfinished helper needs user' test "$(st "$new_pane" @state)" = needs_you

[ "$fail" -eq 0 ] && echo "all passed" || echo "some failed"
exit "$fail"
