#!/usr/bin/env bash
# Resumed Codex threads bind to a verified live identity, preserving routing guards.
# Child-shell commands intentionally contain unexpanded dollars.
# shellcheck disable=SC2016
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-resumed-thread-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-resumed-thread.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  cat > "$tmp/bin/$a" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\0' "$@" > "$TEST_LOG/$TMUX_PANE.args"
printf '%s\n' ready > "$TEST_LOG/$TMUX_PANE.ready"
exec cat
STUB
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH FROM_PANE
unset TMUX_AGENTS_NAME_FORMAT TMUX_START_NAME_EXACT TMUX_START_CHAIN_WORK
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile"
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
quote_command() { python3 - "$@" <<'QUOTE'
import shlex, sys
print(shlex.join(sys.argv[1:]))
QUOTE
}
launch() {
  local cmd
  cmd="$(quote_command "$B/tmux-agents" start codex --name "$1" --exact -- resume resumed-thread)"
  launched="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "$cmd; exec cat")"
  wait_file "$tmp/$launched.ready"
  check "$1 Codex stub started" bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE codex"' _ "$launched"
}
# Invoke the exact notify argv supplied by the launcher, as Codex would.
launch_notify() {
  python3 - "$tmp/$1.args" "$2" <<'NOTIFY'
import json, subprocess, sys
args=open(sys.argv[1], 'rb').read().decode().split('\0')[:-1]
assert args[-2:]==['resume', 'resumed-thread'], args
notify=next(json.loads(a[len('notify='):]) for a in args if a.startswith('notify='))
assert '--agent-id' in notify, notify
subprocess.run(notify+[json.dumps({'type':'agent-turn-complete','thread-id':'resumed-thread',
    'turn-id':sys.argv[2], 'input-messages':['do this work'], 'last-assistant-message':'completed'})], check=True)
NOTIFY
}
launch old
old="$launched" old_id="$(pane_agent_id "$launched")"
launch_notify "$old" original
check 'original thread recorded' test "$(record_get "$old_id" id)" = resumed-thread
tmux send-keys -t "$old" C-d
for ((i=0;i<200;i++)); do [ -z "$(record_get "$old_id" closed)" ] || break; sleep .05; done
check 'launcher exit closes historical identity' test -n "$(record_get "$old_id" closed)"
launch resumed
current="$launched" current_id="$(pane_agent_id "$launched")"
check 'resume launcher assigns distinct identity' test "$current_id" != "$old_id"
"$B/tmux-agent-report" --from resumed 'working on resumed conversation' >/dev/null
# Seed the observed start time, avoiding wall-clock sleeps in accounting assertions.
tmux set -p -t "$current" @turn_start "$(($(date +%s)-9))"
launch_notify "$current" resumed-local
check 'resumed thread binds pane' test "$(info "$current" codex_thread)" = resumed-thread
check 'resumed thread binds current record' test "$(record_get "$current_id" id)" = resumed-thread
check 'local completion returns idle' test "$(info "$current" state)" = idle
check 'observed work completes one turn' test "$(info "$current" turns)" = 1
check 'observed work is banked' test "$(info "$current" worked)" -ge 9
check 'completed work clears start' test -z "$(info "$current" turn_start)"
check 'historical record stays closed' test -n "$(record_get "$old_id" closed)"
# An unfinished explicit local task pauses for the user, without completing it.
"$B/tmux-agent-report" --from resumed --local 'unfinished resumed task' >/dev/null
tmux set -p -t "$current" @turn_start "$(($(date +%s)-7))"
launch_notify "$current" resumed-pending
check 'unfinished task needs user' test "$(info "$current" state)" = needs_you
check 'paused task is not a completed turn' test "$(info "$current" turns)" = 1
check 'paused work is banked' test "$(info "$current" worked)" -ge 16
check 'paused task clears running clock' test -z "$(info "$current" turn_start)"

# Fresh isolated identities for each routing conflict. No fake routing functions.
notify_id() {
  local id="$1" thread="$2"; shift 2
  "$B/tmux-agent-report" "$@" --agent-id "$id" --codex-notify "$(python3 - "$thread" <<'JSON'
import json, sys
print(json.dumps({'type':'agent-turn-complete','thread-id':sys.argv[1],
 'input-messages':['ordinary work'], 'last-assistant-message':'done'}))
JSON
)"
}
new_identity() {
  target="$(tmux new-window -d -P -F '#{pane_id}' cat)"
  set_name "$target" "$1"
  target_id="$(pane_agent_id "$target")"
  record_set "$target_id" name "$1"
  record_set "$target_id" kind codex
  "$B/tmux-agent-report" --from "$1" work >/dev/null
}
for scenario in unknown closed missing live-record live-pane pane-mismatch record-mismatch; do
  new_identity "target-$scenario"
  thread="thread-$scenario"
  case "$scenario" in
    closed|missing|live-record|live-pane)
      owner="$(tmux new-window -d -P -F '#{pane_id}' cat)"
      set_name "$owner" "owner-$scenario"
      owner_id="$(pane_agent_id "$owner")"
      record_set "$owner_id" id "$thread"
      case "$scenario" in
        closed) record_set "$owner_id" closed 123; tmux kill-pane -t "$owner" ;;
        missing) tmux kill-pane -t "$owner" ;;
        live-pane) tmux set -p -t "$owner" @codex_thread "$thread" ;;
      esac ;;
    pane-mismatch) tmux set -p -t "$target" @codex_thread other-thread ;;
    record-mismatch) record_set "$target_id" id other-thread ;;
  esac
  notify_id "$target_id" "$thread"
  case "$scenario" in
    unknown|closed)
      check "$scenario accepts verified live ID" test "$(info "$target" codex_thread)" = "$thread"
      check "$scenario processes completion" test "$(info "$target" state)" = idle ;;
    *)
      check "$scenario does not bind incoming thread" test "$(info "$target" codex_thread)" != "$thread"
      check "$scenario rejects completion" test "$(info "$target" state)" = working
      check "$scenario does not overwrite record" test "$(record_get "$target_id" id)" != "$thread" ;;
  esac
done
# Even after takeover, a callback carrying the old closed identity cannot
# finish current work, and legacy routing cannot attach to a reused label.
"$B/tmux-agent-report" --from resumed work >/dev/null
notify_id "$old_id" resumed-thread
check 'late old explicit ID cannot finish current task' test "$(info "$current" state)" = working
new_identity legacy-target
record_set "$old_id" id legacy-thread
"$B/tmux-agent-report" --codex-notify '{"type":"agent-turn-complete","thread-id":"legacy-thread","input-messages":["[request from boss to legacy-target via tmux-ask]"],"last-assistant-message":"done"}'
check 'legacy closed thread cannot bind reused label' test -z "$(info "$target" codex_thread)"
check 'legacy closed callback leaves work pending' test "$(info "$target" state)" = working
[ "$fail" -eq 0 ] && echo 'all passed' || echo 'some failed'
exit "$fail"
