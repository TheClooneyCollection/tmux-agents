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
export TMUX_AGENTS_NOTES_DIGEST_SECS=0
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
migrate_turn_state

# boss (%0) and its sub agent kid (%1), connected like tmux-spawn does.
tmux split-window cat
TMUX_PANE=%0 "$B/tmux-connect" %1 --as boss <<< kid >/dev/null
tmux set -p -t %1 @parent %0
record_set "$(pane_agent_id %1)" kind codex

fail=0
st() { tmux show -pqv -t "$1" "$2"; }
reset() {
  for p in %0 %1; do
    for o in @explicit_needs_you @attention_since @asking @perm_since @activity @codex_thread @turn_began @last_delivered; do tmux set -pu -t "$p" "$o" 2>/dev/null; done
  done
  tmux set -p -t %1 @tracked 1; tmux set -p -t %1 @state working
}
# Claude hooks for kid; $1 is the prompt that started the turn.
turn_start() { printf '{"prompt":%s}' "$(printf '%s' "$1" | /usr/bin/perl -CA -MJSON::PP -0777 -ne 'print JSON::PP->new->encode($_)')" | "$B/tmux-agent-report" --pane %1 --turn-start; }
end_turn() { "$B/tmux-agent-report" --pane %1 --turn-end </dev/null; }
notify() {  # thread, last assistant message, input message
  "$B/tmux-agent-report" --codex-notify "$(/usr/bin/perl -CA -MJSON::PP -e 'print JSON::PP->new->encode({type=>"agent-turn-complete","thread-id"=>$ARGV[0],"last-assistant-message"=>$ARGV[1],"input-messages"=>[$ARGV[2]]})' "$@")"
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
  end_turn
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
  check "$role notice turn start preserves explicit marker" test "$(st %1 @explicit_needs_you)" = 1
  "$B/tmux-agent-report" --from kid --needs-you "another choice" >/dev/null
  ask %0 kid "new work clears explicit attention"
  expect "$role new request resumes work" working
  check "$role new request clears explicit marker" test -z "$(st %1 @explicit_needs_you)"
done
reset
tmux set -pu -t %1 @parent
"$B/tmux-agent-report" --from kid --needs-you "approve deployment" >/dev/null
end_turn
tmux set -p -t %1 @codex_thread explicit-thread
notify explicit-thread "awaiting approval" "deploy this"
expect "Codex notify preserves explicit attention" needs_you
check "Codex notify preserves reason" test "$(st %1 @activity)" = "approve deployment"
"$B/tmux-agent-report" --from kid "approved, deploying" >/dev/null
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

echo "Claude tool hooks: permission and questions"
tool() {  # event (start|end), tool name; Claude's compact hook JSON
  printf '{"session_id":"s","cwd":"/tmp/a \\"q\\"","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"echo \\"tool_name\\":\\"AskUserQuestion\\""}}' "$2" |
    "$B/tmux-agent-report" --pane %1 "--tool-$1"
}
reset; tmux set -p -t %1 @parent %0
"$B/tmux-agent-report" --pane %1 --perm on
check "permission prompt sets the overlay" test -n "$(st %1 @perm_since)"
tool start Bash
check "next tool call clears permission (user denied the last one)" test -z "$(st %1 @perm_since)"
expect "denied tool leaves the turn working" working
"$B/tmux-agent-report" --pane %1 --perm on
tool end Bash
check "failed or finished tool clears permission" test -z "$(st %1 @perm_since)"
tool start Bash
check "tool call with nothing to clear sets no question" test -z "$(st %1 @asking)"
expect "quoted AskUserQuestion inside tool input is not a question" working
tool start AskUserQuestion
expect "AskUserQuestion needs the user at once" needs_you
check "question marks its own attention" test -n "$(st %1 @attention_since)" -a "$(st %1 @asking)" = 1
tool end AskUserQuestion
expect "answered question resumes work" working
check "answer clears question markers" test -z "$(st %1 @asking)$(st %1 @attention_since)"
tool start AskUserQuestion
turn_start "carry on"
expect "dismissed question cleared by the next prompt" working
check "turn start clears the question marker" test -z "$(st %1 @asking)"
reset; tmux set -p -t %1 @parent %0
"$B/tmux-agent-report" --from kid --needs-you "approve deploy" >/dev/null
tool start AskUserQuestion
tool end AskUserQuestion
expect "answer keeps explicit attention" needs_you
check "explicit attention keeps its reason" test "$(st %1 @activity)" = "approve deploy"
reset
"$B/tmux-agent-report" --pane %1 --asking
"$B/tmux-agent-report" --from kid --needs-you "explicit during question" >/dev/null
tool end AskUserQuestion
expect "question result preserves newer explicit attention" needs_you
check "explicit attention timestamp survives question result" test -n "$(st %1 @attention_since)"
# MCP elicitation: Notification[elicitation_dialog] -> --asking, then
# ElicitationResult (accept, decline or cancel) -> --tool-end.
elicit() { printf '{"hook_event_name":"%s","notification_type":"elicitation_dialog"}' "$1" | "$B/tmux-agent-report" --pane %1 "$2"; }
reset; tmux set -p -t %1 @parent %0
elicit Notification --asking
expect "elicitation dialog needs the user" needs_you
check "elicitation marks its own attention" test -n "$(st %1 @attention_since)" -a "$(st %1 @asking)" = 1
elicit Notification --asking
check "repeated elicitation notice keeps one question" test "$(st %1 @asking)" = 1
elicit ElicitationResult --tool-end
expect "elicitation result resumes work" working
check "elicitation result clears question markers" test -z "$(st %1 @asking)$(st %1 @attention_since)"
elicit Notification --asking
tool start Bash
expect "next tool call clears an elicitation" working
elicit Notification --asking
"$B/tmux-agent-report" --pane %1 --turn-end </dev/null
check "turn end retains unanswered elicitation provenance" test "$(st %1 @asking)" = 1
reset; tmux set -p -t %1 @parent %0
"$B/tmux-agent-report" --from kid --needs-you "pick a region" >/dev/null
elicit Notification --asking
elicit ElicitationResult --tool-end
expect "elicitation answer keeps explicit attention" needs_you
check "explicit attention keeps its reason after elicitation" test "$(st %1 @activity)" = "pick a region"
"$B/tmux-agent-report" --pane %1 --perm on
elicit ElicitationResult --tool-end
check "elicitation result also clears permission" test -z "$(st %1 @perm_since)"

reset; tmux set -p -t %1 @parent %0
turn_start "local work"
"$B/tmux-agent-report" --pane %1 --perm on
"$B/tmux-agent-report" --pane %1 --turn-end </dev/null
check "StopFailure turn end clears permission" test -z "$(st %1 @perm_since)"
check "StopFailure turn end stops the turn clock" test -z "$(st %1 @turn_start)" -a "$(st %1 @state)" != working
# Invoked through check.
# shellcheck disable=SC2329
gone_pane_hook() { printf '{}' | "$B/tmux-agent-report" --pane %999 --tool-start; }
# shellcheck disable=SC2329
paneless_hook() { ! "$B/tmux-agent-report" --tool-end </dev/null 2>/dev/null; }
check "tool hook on a missing pane is a no-op" gone_pane_hook
check "tool hook needs a pane" paneless_hook

# Startup trust is a permission overlay, not a model turn or explicit question.
reset
identity="$(pane_agent_id %1)"
_agent_work %1 startup-perm on '' "$identity"
check "startup trust stops work clock" test -z "$(st %1 @turn_start)"
check "startup trust sets permission" test -n "$(st %1 @perm_since)"
"$B/tmux-agent-report" --from kid --needs-you 'choose region after startup' >/dev/null
_agent_work %1 startup-perm '' '' "$identity"
expect "startup cleanup preserves explicit attention" needs_you
check "startup cleanup preserves new activity" test "$(st %1 @activity)" = 'choose region after startup'
reset
_agent_work %1 startup-perm on '' "$identity"
"$B/tmux-agent-report" --pane %1 --perm on
_agent_work %1 startup-perm '' '' "$identity"
check "new explicit permission retains ownership at same timestamp" test -n "$(st %1 @perm_since)"

# Quiet progress cannot act as the answer to an explicit user question.
reset
"$B/tmux-agent-report" --from kid --needs-you 'choose deployment region' >/dev/null
before="$(st %1 @last_delivered)"
"$B/tmux-ask" --from boss --note kid 'background build is ready' >/dev/null
expect "quiet note preserves explicit needs-you" needs_you
check "quiet note preserves delivery token" test "$(st %1 @last_delivered)" = "$before"
check "quiet note is available without starting a turn" test "$("$B/tmux-notes" --from kid --count)" -gt 0
"$B/tmux-notes" --from kid >/dev/null
expect "reading quiet notes preserves explicit needs-you" needs_you

exit "$fail"
