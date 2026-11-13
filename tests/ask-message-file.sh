#!/usr/bin/env bash
# tmux-ask --message-file interface tests on an isolated server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; B="$here/bin"
sock="ask-file-$$"; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ask-file.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d cat
tmux -L "$sock" has-session || { echo 'ABORT: no test server'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0"
tmux set-option -g default-shell /bin/sh
tmux new-window -d cat
tmux set -p -t %0 @agent sender; tmux set -p -t %1 @agent receiver
tmux set -p -t %0 @peers %1; tmux set -p -t %1 @peers %0
. "$B/lib.sh"; ensure_agent_ids "$tmp/empty"
Q="/tmp/tmux-agents-$(id -u)/queue/$(basename "${TMUX%%,*}")"
fail() { echo "FAIL: $*" >&2; exit 1; }
file="$tmp/body"
# shellcheck disable=SC2016
printf 'literal $HOME\nline two\n' > "$file"
last_file=""
send() {
  local before=" " candidate rc
  for candidate in "$Q"/*.msg; do
    [ -f "$candidate" ] || continue
    before="$before$candidate "
  done
  "$@" || { rc=$?; return "$rc"; }
  last_file=""
  for candidate in "$Q"/*.msg; do
    [ -f "$candidate" ] || continue
    case "$before" in *" $candidate "*) continue ;; esac
    [ -z "$last_file" ] || fail 'multiple messages published by one send'
    last_file="$candidate"
  done
  [ -n "$last_file" ] && [ -f "${last_file%.msg}.meta" ] || fail 'message and metadata not published'
}
ask() { send env TMUX_PANE=%0 "$B/tmux-ask" --from sender receiver "$@"; }
tmux copy-mode -t %1
latest() { printf '%s\n' "$last_file"; }
assert_body() { f="$(latest)"; grep -Fq -- "$1" "$f" || fail "body missing $1"; }
assert_kind() { f="$(latest)"; grep -q "kind=$1" "${f%.msg}.meta" || fail "kind $1"; }
ask --message-file "$file" < <(printf 'ignored stdin payload'); assert_kind request
# shellcheck disable=SC2016
assert_body 'literal $HOME'
assert_body 'short reply as a quoted argument: tmux-ask --from receiver --request-id '
assert_body ' --reply sender "answer"'
if grep -Fq 'ignored stdin payload' "$(latest)"; then fail 'stdin is ignored when a message file is supplied'; fi
if grep -Fq "<<'MSG'" "$(latest)"; then fail 'request reply command avoids heredoc'; fi
# Use the generated request id to exercise reply handling.
rid="$(sed -n 's/^request_id=//p' "$(latest | sed 's/\.msg$/.meta/')")"
tmux copy-mode -t %0
send env TMUX_PANE=%1 "$B/tmux-ask" --from receiver --reply --request-id "$rid" --message-file "$file" sender
assert_kind reply; assert_body 'line two'
ask --notice --message-file "$file"; assert_kind notice
ask --any --message-file "$file"; assert_kind request
ask --message-file "$file" extra
assert_body extra
assert_body 'Read the full message here: tmux-read '
if ask --message-file "$file" '' >"$tmp/error" 2>&1; then fail empty-positional-conflict; fi
grep -q 'empty message' "$tmp/error" || fail empty-summary-error
# A pipe with a writer still open and no data must not block the file path.
mkfifo "$tmp/idle-stdin"
exec 9<>"$tmp/idle-stdin"
(
  env TMUX_PANE=%0 "$B/tmux-ask" --from sender --message-file "$file" receiver <"$tmp/idle-stdin" >"$tmp/idle.out" 2>"$tmp/idle.err" &
  command_pid=$!
  (
    sleep 5 & timer_pid=$!
    trap 'kill "$timer_pid" 2>/dev/null || :' EXIT
    wait "$timer_pid"
    kill "$command_pid" 2>/dev/null || :
  ) &
  watchdog_pid=$!
  status=0
  wait "$command_pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || :
  wait "$watchdog_pid" 2>/dev/null || :
  printf '%s\n' "$status" >"$tmp/idle.status"
) &
idle_pid=$!
for ((i = 0; i < 120; i++)); do [ -f "$tmp/idle.status" ] && break; sleep 0.05; done
if [ ! -f "$tmp/idle.status" ]; then
  kill "$idle_pid" 2>/dev/null || :
  wait "$idle_pid" 2>/dev/null || :
  exec 9>&-
  fail 'message-file does not read an inherited idle stdin pipe'
fi
wait "$idle_pid" || fail 'idle-pipe message process exits cleanly'
[ "$(cat "$tmp/idle.status")" = 0 ] || { cat "$tmp/idle.err" >&2; fail 'idle-pipe message succeeds'; }
exec 9>&-
if ask --message-file >"$tmp/error" 2>&1; then fail missing-path; fi
grep -q -- '--message-file needs a path' "$tmp/error" || fail missing-path-error
if ask --message-file '' >"$tmp/error" 2>&1; then fail empty-path; fi
grep -q -- '--message-file needs a path' "$tmp/error" || fail empty-path-error
if ask --message-file '' --message-file "$file" >"$tmp/error" 2>&1; then fail duplicate-empty-option; fi
grep -q 'may only be used once' "$tmp/error" || fail duplicate-empty-option-error
: > "$tmp/empty"
if ask --message-file "$tmp/empty" >"$tmp/error" 2>&1; then fail empty-file; fi
grep -q 'empty message' "$tmp/error" || fail empty-file-error
if ask --message-file "$tmp/missing" >"$tmp/error" 2>&1; then fail missing-file; fi
grep -q 'regular file' "$tmp/error" || fail missing-file-error
if ask --message-file "$file" --message-file "$file" >"$tmp/error" 2>&1; then fail duplicate-option; fi
grep -q 'may only be used once' "$tmp/error" || fail duplicate-option-error
ln -s "$file" "$tmp/link"
if ask --message-file "$tmp/link" >"$tmp/error" 2>&1; then fail symlink; fi
grep -q 'must not be a symlink' "$tmp/error" || fail symlink-error
mkdir "$tmp/dir"
if ask --message-file "$tmp/dir" >"$tmp/error" 2>&1; then fail nonregular; fi
grep -q 'regular file' "$tmp/error" || fail nonregular-error
head -c 1048577 /dev/zero | tr '\000' x > "$tmp/large"
if ask --message-file "$tmp/large" >"$tmp/error" 2>&1; then fail oversize; fi
grep -q '1048576-byte limit' "$tmp/error" || fail oversize-error
chmod 000 "$file"
if [ "$(id -u)" -ne 0 ]; then
  if ask --message-file "$file" >"$tmp/error" 2>&1; then fail unreadable; fi
  grep -q 'not readable' "$tmp/error" || fail unreadable-error
fi
printf 'ok: message-file request/reply/notice/any and validation cases\n'
