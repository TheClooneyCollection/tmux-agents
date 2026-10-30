#!/usr/bin/env bash
# Shared bounded text-file reader and actionable tmux connection failures.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-message-file-shared-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-message-file-shared.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE
export XDG_STATE_HOME="$tmp/state"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat </dev/null
tmux -L "$sock" has-session || { echo 'ABORT: private test server unavailable'; exit 1; }
socket="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
mkdir "$tmp/bin"
cat >"$tmp/bin/tmux" <<'STUB'
#!/bin/sh
case "${TEST_TMUX_ERROR:-}" in
  denied) echo 'error connecting to private socket (Operation not permitted)' >&2 ;;
  missing) echo 'error connecting to private socket (No such file or directory)' >&2 ;;
  noserver) echo 'no server running on private socket' >&2 ;;
esac
[ -z "${TEST_TMUX_ERROR:-}" ] || exit 1
exec "$TEST_REAL_TMUX" "$@"
STUB
chmod +x "$tmp/bin/tmux"
export TEST_REAL_TMUX="$(command -v tmux)"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
read_value() { /bin/bash -c '. "$1/lib.sh"; read_message_file value "$2"; printf "<%s>" "$value"' test "$B" "$1"; }
tricky=$'literal $(touch nope)\nsecond line\n'
printf '%s' "$tricky" >"$tmp/message"
check 'reader preserves literal text and trailing newlines' test "$(read_value "$tmp/message")" = "<$tricky>"
ln -s "$tmp/message" "$tmp/link"
if /bin/bash -c '. "$1/lib.sh"; read_message_file value "$2"' test "$B" "$tmp/link" >"$tmp/error" 2>&1; then echo 'FAIL reader rejects symlink'; fail=1; else check 'reader rejects a symlink' grep -q 'must not be a symlink' "$tmp/error"; fi
: >"$tmp/empty"
check 'reader preserves empty file' test "$(read_value "$tmp/empty")" = '<>'
head -c 1048576 /dev/zero | tr '\000' x >"$tmp/max"
check 'reader accepts exactly one MiB text' test "$(wc -c <"$tmp/max" | tr -d ' ')" = 1048576
head -c 1048577 /dev/zero | tr '\000' x >"$tmp/large"
if /bin/bash -c '. "$1/lib.sh"; read_message_file value "$2"' test "$B" "$tmp/large" >"$tmp/error" 2>&1; then
  echo 'FAIL reader rejects oversized file'; fail=1
else
  check 'oversized file has actionable limit' grep -q '1048576-byte limit' "$tmp/error"
fi
printf 'a\0b' >"$tmp/binary"
if /bin/bash -c '. "$1/lib.sh"; read_message_file value "$2"' test "$B" "$tmp/binary" >"$tmp/error" 2>&1; then
  echo 'FAIL reader rejects NUL text'; fail=1
else
  check 'NUL content names text restriction' grep -q 'without NUL bytes' "$tmp/error"
fi
run_connection() {
  PATH="$tmp/bin:$PATH" TMUX="$socket,1,0" TEST_TMUX_ERROR="$1" \
    /bin/bash -c '. "$1/lib.sh"; require_tmux' test "$B"
}
run_connection denied >"$tmp/denied" 2>&1 && { echo 'FAIL denied socket rejected'; fail=1; }
check 'permission error explains file argv and escalation' grep -q 'permission denied.*--message-file.*narrow escalation' "$tmp/denied"
run_connection missing >"$tmp/missing" 2>&1 && { echo 'FAIL missing socket rejected'; fail=1; }
check 'dead socket error suggests reconnect' grep -q 'socket is missing or inactive.*TMUX' "$tmp/missing"
PATH="$tmp/bin:$PATH" TEST_TMUX_ERROR=noserver TMUX= /bin/bash -c '. "$1/lib.sh"; require_tmux' test "$B" >"$tmp/no-server" 2>&1 && { echo 'FAIL absent server accepted'; fail=1; }
check 'no TMUX server retains clear message' grep -q 'no tmux server running' "$tmp/no-server"
[ "$fail" -eq 0 ] && echo 'all passed' || echo 'some failed'
exit "$fail"
