#!/usr/bin/env bash
# Real queue -> receiver closure -> bounce -> resume, on an isolated server.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-resume-test-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-resume.XXXXXX")"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  cleanup_test_server || return
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'STUB'
#!/bin/sh
stty -echo
printf 'STUB READY\n'
exec cat >>"$RESUME_MESSAGES_LOG"
STUB
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin"
export RESUME_MESSAGES_LOG="$tmp/received"
export TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0 TMUX_ASK_QUEUE_SECS=1800
: >"$RESUME_MESSAGES_LOG"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 60 -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# Avoid personal startup files changing the isolated environment.
tmux set-option -g default-shell /bin/sh
tmux set-option -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0 count=0
check() {
  local label="$1"; shift
  count=$((count + 1))
  if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi
}
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
wait_for() {
  local i=0
  while [ "$i" -lt 100 ]; do
    if "$@"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
info() { tmux display-message -p -t "$1" "#{$2}"; }
spawn() { "$B/tmux-spawn" "$@" --from main </dev/null; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
ready() { tmux capture-pane -p -S -100 -t "$1" | grep -q 'STUB READY'; }
file_count() { find "$queue" -name "$1" -type f | wc -l | tr -d ' '; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
bounced() { [ "$(file_count '*.undelivered')" -eq 3 ]; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
original_metadata_intact() {
  local f
  for f in "$tmp"/original/*.meta; do
    cmp -s "$f" "$queue/${f##*/}" || return 1
  done
}
receiver_file_count() {
  local extension="$1" f n=0 current="${new:-none}"
  current="${current#%}"
  for f in "$queue"/*."$extension"; do
    [ -f "$f" ] || continue
    case "$f" in
      *-"${old#%}"."$extension"|*-"$current"."$extension") n=$((n+1)) ;;
    esac
  done
  printf '%s\n' "$n"
}
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
notices_queued() { [ "$(find "$queue" -name '*-0.msg' -type f | wc -l | tr -d ' ')" = 3 ]; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
received() { cmp -s "$tmp/expected" "$RESUME_MESSAGES_LOG"; }
spawn claude --exact --name receiver >"$tmp/spawn"
old="$(pane_of receiver)"
receiver_id="$(pane_agent_id "$old")"
check 'stub receiver is ready' wait_for ready "$old"
if [ "$fail" -ne 0 ]; then
  cat "$tmp/spawn"
  [ -z "$old" ] || tmux capture-pane -p -S -100 -t "$old"
  exit 1
fi
tmux copy-mode -t "$old"
check 'receiver is busy in copy mode' test "$(info "$old" pane_in_mode)" = 1
# Distinct epochs make order unambiguous even across PID wraparound.
"$B/tmux-ask" --from main --notice receiver 'resume-first-notice' >"$tmp/queued-1"
sleep 1
"$B/tmux-ask" --from main --reply receiver 'resume-second-reply' >"$tmp/queued-2"
sleep 1
"$B/tmux-ask" --from main receiver 'resume-third-request' >"$tmp/queued-3"
check 'all three sends really queued' test "$(grep -l '^queued ' "$tmp"/queued-* | wc -l | tr -d ' ')" = 3
check 'queue retains all three message bodies' test "$(file_count '*.msg')" = 3
check 'every queued message has metadata' test "$(file_count '*.meta')" = 3
mkdir "$tmp/original"
: >"$tmp/expected"
# Keep byte-exact originals, including headers, reply instructions and kinds.
for f in $(find "$queue" -name '*.msg' | sort); do
  cp "${f%.msg}.meta" "$tmp/original/"
  cat "$f" >>"$tmp/expected"
  printf '\n' >>"$tmp/expected"
done
# Hold bounce notices at the sender so their own metadata coexists with
# the original messages deterministically, even on an otherwise idle machine.
tmux copy-mode -t %0
"$B/tmux-dismiss" --from main receiver >"$tmp/dismiss"
check 'receiver is actually gone' test -z "$(pane_of receiver)"
check 'delivery workers bounce all three after closure' wait_for bounced
check 'three bounce notices remain queued for the busy sender' wait_for notices_queued
check 'bounce metadata coexists with all original metadata' test "$(file_count '*.meta')" = 6
check 'bounce retains all message metadata' original_metadata_intact
check 'nothing was delivered before resume' test ! -s "$RESUME_MESSAGES_LOG"
# Reusing a closed label must never steal its queued conversation.
spawn claude --exact --name receiver >"$tmp/replacement"
replacement="$(pane_of receiver)"
check 'replacement stub is ready' wait_for ready "$replacement"
check 'replacement has a different identity' test "$(pane_agent_id "$replacement")" != "$receiver_id"
"$B/tmux-ask" --retry --to receiver >"$tmp/wrong-retry"
check 'same-name replacement receives no old messages' test ! -s "$RESUME_MESSAGES_LOG"
check 'same-name retry preserves all originals' original_metadata_intact
# Resume keeps the original ID even when its label needs a suffix.
spawn --resume receiver >"$tmp/resume"
new="$(pane_of receiver-2)"
check 'resume creates a different pane' test "$new" != "$old"
check 'resume assigns an available label' test "$(info "$new" @agent)" = receiver-2
check 'resume restores ownership before retry' test "$(info "$new" @parent)" = %0
check 'resume delivers original messages exactly once, oldest first' wait_for received
check 'retried request leaves resumed receiver working' test "$(info "$new" @state)" = working
check 'sender still awaits the resumed receiver' test "$(info %0 @awaiting)" = "$receiver_id"
check 'successful retry removes saved messages' test "$(receiver_file_count undelivered)" = 0
check 'successful retry leaves no queued messages' test "$(receiver_file_count msg)" = 0
check 'successful retry removes metadata' test "$(receiver_file_count meta)" = 0
check 'retry leaves unrelated bounce notices queued' notices_queued
"$B/tmux-ask" --retry --to receiver-2 >"$tmp/retry-again"
check 'explicit retry does not duplicate delivered messages' received
"$B/tmux-dismiss" --from main receiver-2 >"$tmp/dismiss-again"
spawn --resume receiver-2 >"$tmp/resume-again"
new="$(pane_of receiver-2)"
check 'resume without pending messages stays done' test "$(info "$new" @state)" = "done"
check 'second resume does not replay delivered messages' received
printf '%s checks; failures=%s\n' "$count" "$fail"
exit "$fail"
