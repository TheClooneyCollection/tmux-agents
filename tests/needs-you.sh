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
    for o in @attention_since @waiting_on @awaiting @activity @codex_thread @request_local_work @request_local_done @request_progress_at @request_pending_since; do tmux set -pu -t "$p" "$o" 2>/dev/null; done
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

echo "Top-level turn ends and wakeups"
reset
tmux set -pu -t %1 @parent
turn_start "user task"
tmux set -p -t %1 @attention_since 1
"$B/tmux-agent-report" --pane %1 --local-done
turn_end
expect "top-level with nothing pending goes idle" idle
check "top-level clears old attention" test -z "$(st %1 @attention_since)"
check "idle completes the worked-time turn" test "$(st %1 @turns)" = 1
check "idle stops active work clock" test -z "$(st %1 @turn_start)"
turn_end
check "duplicate idle turn end does not count twice" test "$(st %1 @turns)" = 1
turn_start "next user prompt"
expect "turn-start wakes idle top-level" working
"$B/tmux-agent-report" --pane %1 --local-done
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
expect "incoming reply preserves independent local task" needs_you
"$B/tmux-agent-report" --pane %1 --local-done
turn_end
expect "top-level goes idle after all requests and local work finish" idle
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
expect "Codex direct user input reopens done as unfinished local work" needs_you
check "Codex direct input retains local obligation" test "$(st %1 @request_local_work)" = 1

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

[ "$fail" -eq 0 ] && echo "all passed" || echo "some failed"
exit "$fail"
