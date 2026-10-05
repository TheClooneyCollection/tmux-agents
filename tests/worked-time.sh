#!/usr/bin/env bash
# Deterministic work accounting, paused overlays, duplicate hooks and resume.
# All processes and records belong to a private tmux server; no live agents run.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-worked-time-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-worked-time.XXXXXX")"
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
clear_work() {
  local field
  for field in state started state_since worked last_turn turns turn_start perm_since msg_waiting_since; do
    tmux set -pu -t %0 "@$field"
  done
}
# The old pane's true start cannot be recovered from its age or stale state.
clear_work
tmux set -p -t %0 @state working
expect 'legacy pane has unknown work' %0 worked ''
agent_set_state %0 working 100
expect 'first post-upgrade report starts accounting now' %0 turn_start 100
expect 'legacy started remains unknown' %0 started ''
agent_set_state %0 working 110
expect 'repeated working does not reset interval' %0 turn_start 100
agent_set_state %0 "done" 130
expect 'first finished interval' %0 worked 30
expect 'last turn duration' %0 last_turn 30
expect 'first completed turn' %0 turns 1
expect 'state transition timestamp' %0 state_since 130
agent_set_state %0 "done" 140
expect 'duplicate completion does not add a turn' %0 turns 1
expect 'duplicate completion preserves state time' %0 state_since 130
agent_set_state %0 working 200
agent_set_state %0 idle 220
expect 'working to idle adds work' %0 worked 50
agent_set_state %0 working 300
agent_set_state %0 needs_you 345
expect 'working to needs-you adds work' %0 worked 95
expect 'needs-you pauses third turn without completing it' %0 turns 2
expect 'needs-you preserves previous last turn' %0 last_turn 20
expect 'paused turn has no active interval' %0 turn_start ''
# Overlay waits leave the semantic state working, but suspend accounting.
agent_set_state %0 working 400
agent_set_wait %0 perm 410 410
expect 'permission overlay retains semantic state' %0 state working
expect 'permission banks active seconds' %0 worked 105
expect 'permission has no active work clock' %0 turn_start ''
agent_set_wait %0 perm 410 420
expect 'duplicate permission hook adds no time' %0 worked 105
agent_set_wait %0 perm '' 450
expect 'permission clear resumes at current time' %0 turn_start 450
agent_set_wait %0 message 460 460
expect 'queued message suspends work' %0 worked 115
agent_set_wait %0 perm 470 470
agent_set_wait %0 message '' 480
expect 'overlapping permission still pauses work' %0 turn_start ''
agent_set_wait %0 perm '' 500
expect 'last overlay clear resumes work' %0 turn_start 500
agent_set_state %0 "done" 520
expect 'wait durations excluded from total' %0 worked 135
expect 'completed turn totals active intervals excluding waits' %0 last_turn 85
expect 'pauses belong to the same third turn' %0 turns 3
# Each wait mode pauses one turn. Duplicate markers and overlapping waits
# cannot complete a turn, reset its accumulated seconds, or double-count it.
for pause in perm message needs_you overlap; do
  pause_pane="$(tmux new-window -d -P -F '#{pane_id}' cat </dev/null)"
  agent_set_state "$pause_pane" working 100
  case "$pause" in
    needs_you) agent_set_state "$pause_pane" needs_you 110 ;;
    overlap) agent_set_wait "$pause_pane" perm 110 110
      agent_set_wait "$pause_pane" message 112 112 ;;
    *) agent_set_wait "$pause_pane" "$pause" 110 110 ;;
  esac
  expect "$pause banks ten active seconds while paused" "$pause_pane" worked 10
  expect "$pause does not complete the turn" "$pause_pane" turns 0
  expect "$pause does not replace last completed turn" "$pause_pane" last_turn ''
  case "$pause" in
    needs_you) agent_set_state "$pause_pane" needs_you 120
      agent_set_state "$pause_pane" working 130 ;;
    overlap) agent_set_wait "$pause_pane" perm 115 115
      agent_set_wait "$pause_pane" perm '' 120
      expect 'remaining message overlay keeps turn paused' "$pause_pane" turn_start ''
      agent_set_wait "$pause_pane" message '' 130 ;;
    *) agent_set_wait "$pause_pane" "$pause" 120 120
      agent_set_wait "$pause_pane" "$pause" '' 130 ;;
  esac
  expect "$pause resumes same turn without counting a completion" "$pause_pane" turns 0
  expect "$pause excludes paused wall time" "$pause_pane" worked 10
  agent_set_state "$pause_pane" "done" 150
  expect "$pause whole-turn active time" "$pause_pane" worked 30
  expect "$pause last turn sums both intervals" "$pause_pane" last_turn 30
  expect "$pause completes exactly one turn" "$pause_pane" turns 1
  agent_set_state "$pause_pane" "done" 160
  expect "$pause duplicate completion retains turn count" "$pause_pane" turns 1
  agent_set_state "$pause_pane" working 170
  agent_set_state "$pause_pane" needs_you 175
  agent_set_state "$pause_pane" idle 200
  expect "$pause idle completes the paused turn" "$pause_pane" turns 2
  expect "$pause idle records only active seconds" "$pause_pane" last_turn 5
  tmux set -p -t "$pause_pane" @agent "pause-$pause"
  pause_id="$(ensure_agent_id "$pause_pane")"
  agent_set_state "$pause_pane" working 210
  agent_set_state "$pause_pane" needs_you 220
  agent_save_work "$pause_pane" 250
  check "$pause close persists completed paused turn" test "$(record_get "$pause_id" turns)" = 3
  check "$pause close excludes pause from last turn" test "$(record_get "$pause_id" last_turn)" = 10
  check "$pause close preserves all worked seconds" test "$(record_get "$pause_id" worked)" = 45
  tmux kill-pane -t "$pause_pane"
done
# Helpers round-trip completed work without adding idle time or inventing start.
aid="$(pane_agent_id %0)"
tmux set -p -t %0 @activity $'review=full\nkind=not-a-record-key\ntail\t完'
agent_save_work %0 600
check 'activity flattens line breaks and preserves equals' test "$(record_get "$aid" activity)" = 'review=full kind=not-a-record-key tail 完'
check 'activity cannot inject record keys' test "$(record_get "$aid" kind)" != not-a-record-key
check 'saved completed work' test "$(record_get "$aid" worked)" = 135
check 'saved legacy start is unknown' test "$(record_get "$aid" started)" = ''
restored="$(tmux new-window -d -P -F '#{pane_id}' cat </dev/null)"
agent_restore_work "$restored" "$aid" 700
expect 'restored completed total' "$restored" worked 135
expect 'restored legacy start still unknown' "$restored" started ''
agent_set_state "$restored" working 800
agent_set_state "$restored" "done" 825
expect 'restored agent keeps accumulating' "$restored" worked 160
agent_set_state "$restored" working 830
agent_restore_work "$restored" "$aid" 900
expect 'same-ID restore preserves active state' "$restored" state working
expect 'same-ID restore preserves active interval' "$restored" turn_start 830
expect 'same-ID restore preserves new completed work' "$restored" worked 160
expect 'same-ID restore preserves state timestamp' "$restored" state_since 830
agent_set_state "$restored" "done" 850
expect 'work after repeated restore keeps accumulating' "$restored" worked 180
# Real entry points: freshly spawned agents record start, dismiss persists it,
# and reopening keeps both identity and total. Stubs never run actual agents.
# Invoked through check.
# shellcheck disable=SC2329
ready() {
  local pane="$1" kind="$2" i
  [ -n "$pane" ] || return 1
  for ((i=0; i<100; i++)); do
    if tmux capture-pane -p -t "$pane" | grep -q "STUB READY $kind"; then return 0; fi
    sleep .05
  done
  return 1
}
"$B/tmux-spawn" claude --from main --name clock-child --exact </dev/null >"$tmp/spawn"
pane="$(find_pane clock-child)"
check 'spawn uses Claude stub' ready "$pane" claude
started="$(opt "$pane" started)"
check 'new spawn has numeric started time' test "${started:-0}" -gt 0
child_id="$(pane_agent_id "$pane")"
# Set a closed deterministic interval before dismissal (no wall-clock drift).
agent_set_state "$pane" working 1000
agent_set_state "$pane" "done" 1060
expect 'spawned agent finishes one minute' "$pane" worked 60
"$B/tmux-dismiss" --from main clock-child </dev/null >"$tmp/dismiss"
check 'dismiss persists work' test "$(record_get "$child_id" worked)" = 60
check 'dismiss persists started' test "$(record_get "$child_id" started)" = "$started"
"$B/tmux-spawn" --from main --resume-id "$child_id" </dev/null >"$tmp/resume"
pane="$(find_pane clock-child)"
check 'resume uses Claude stub' ready "$pane" claude
expect 'resume retains started' "$pane" started "$started"
expect 'resume retains total' "$pane" worked 60
agent_set_state "$pane" working 2000
agent_set_state "$pane" "done" 2025
expect 'resume adds work' "$pane" worked 85
expect 'resume retains and increments turn count' "$pane" turns 2
# Force the child to report before the parent receives the new pane ID.
# The new-window shim is a handshake barrier, not a scheduling sleep. Without
# pre-exec restore + same-ID idempotence, the parent's late restore erases work.
"$B/tmux-dismiss" --from main clock-child </dev/null >"$tmp/race-dismiss"
mkdir "$tmp/gate"
tmux set-option -g remain-on-exit on
WORK_REAL_TMUX="$(command -v tmux)"
WORK_RACE_READY="$tmp/race-ready"
export WORK_REAL_TMUX WORK_RACE_READY
# Explicit test-server environment reaches the agent stub, never live panes.
tmux set-environment -g WORK_REAL_TMUX "$WORK_REAL_TMUX"
tmux set-environment -g WORK_RACE_BIN "$B"
tmux set-environment -g WORK_RACE_READY "$WORK_RACE_READY"
cat >"$tmp/bin/claude" <<'STUB'
#!/bin/bash
set -eu
# shellcheck disable=SC1091
. "$WORK_RACE_BIN/lib.sh"
# These transitions simulate a resumed agent's immediate incoming work; the
# following real report is deliberately before parent adoption/restore.
agent_set_state "$TMUX_PANE" working 4000
agent_set_state "$TMUX_PANE" "done" 4005
agent_set_state "$TMUX_PANE" working 4010
"$WORK_RACE_BIN/tmux-agent-report" --pane "$TMUX_PANE" 'early resumed work' </dev/null
printf '%s\n' "$TMUX_PANE" >"$WORK_RACE_READY.tmp"
mv "$WORK_RACE_READY.tmp" "$WORK_RACE_READY"
echo 'STUB READY claude'
exec cat
STUB
cat >"$tmp/gate/tmux" <<'STUB'
#!/bin/bash
set -eu
case "$1" in
  new-window|new-session)
    pane="$("$WORK_REAL_TMUX" "$@")"
    for ((i=0; i<200; i++)); do
      if [ -f "$WORK_RACE_READY" ]; then
        [ "$(cat "$WORK_RACE_READY")" = "$pane" ] || { echo 'wrong handshake pane' >&2; exit 1; }
        printf '%s\n' "$pane"
        exit 0
      fi
      sleep .05
    done
    "$WORK_REAL_TMUX" capture-pane -p -t "$pane" >&2 || true
    echo 'FAIL resume stub did not reach early-report barrier' >&2
    exit 1 ;;
  *) exec "$WORK_REAL_TMUX" "$@" ;;
esac
STUB
chmod +x "$tmp/bin/claude" "$tmp/gate/tmux"
PATH="$tmp/gate:$PATH" "$B/tmux-spawn" --from main --resume-id "$child_id" </dev/null >"$tmp/race-resume"
pane="$(find_pane clock-child)"
check 'early resumed stub passed handshake' test "$(cat "$WORK_RACE_READY")" = "$pane"
check 'early resumed agent uses Claude stub' ready "$pane" claude
expect 'parent restore preserves early working report' "$pane" state working
expect 'parent restore preserves early active interval' "$pane" turn_start 4010
expect 'parent restore preserves historical and early work' "$pane" worked 90
expect 'parent restore preserves early completed turn' "$pane" turns 3
expect 'parent restore preserves original started time' "$pane" started "$started"
agent_restore_work "$pane" "$child_id" 4020
expect 'another same-ID restore keeps early active interval' "$pane" turn_start 4010
agent_set_state "$pane" "done" 4030
expect 'early resumed interval continues after parent restore' "$pane" worked 110
"$B/tmux-spawn" codex --from main --name codex-clock --exact </dev/null >"$tmp/codex"
check 'Codex also uses stub' ready "$(find_pane codex-clock)" codex
# Real hooks choose their own wall clock. Seed a known earlier interval and
# assert idempotence rather than freezing date (the helper can use Perl time).
hooks="$(find_pane codex-clock)"
hook_start="$(( $(date +%s) - 30 ))"
agent_set_state "$hooks" working "$hook_start"
printf '%s\n' '{"prompt":"implement regression fixture"}' >"$tmp/turn-start.json"
"$B/tmux-agent-report" --pane "$hooks" --turn-start <"$tmp/turn-start.json"
expect 'real start hook retains active interval' "$hooks" turn_start "$hook_start"
"$B/tmux-agent-report" --pane "$hooks" --turn-start <"$tmp/turn-start.json"
expect 'duplicate real start hook retains interval' "$hooks" turn_start "$hook_start"
"$B/tmux-agent-report" --pane "$hooks" --turn-end </dev/null
hook_work="$(opt "$hooks" worked)" hook_since="$(opt "$hooks" state_since)"
check 'real end hook banks active work' test "${hook_work:-0}" -ge 30
expect 'real end hook flags needs you' "$hooks" state needs_you
"$B/tmux-agent-report" --pane "$hooks" --turn-end </dev/null
expect 'needs-you hooks keep turn paused, not completed' "$hooks" turns 0
expect 'duplicate real end hook keeps total' "$hooks" worked "$hook_work"
expect 'duplicate real end hook keeps state age' "$hooks" state_since "$hook_since"
[ "$fail" -eq 0 ] && echo 'all passed' || echo 'some failed'
exit "$fail"
