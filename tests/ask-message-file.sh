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
send() { TMUX_PANE=%0 "$B/tmux-ask" --from sender "$@"; }
tmux copy-mode -t %1
latest() { find "$Q" -name '*.msg' -type f | sort | tail -n 1; }
assert_body() { f="$(latest)"; grep -Fq -- "$1" "$f" || fail "body missing $1"; }
assert_kind() { f="$(latest)"; grep -q "kind=$1" "${f%.msg}.meta" || fail "kind $1"; }
send --message-file "$file" receiver; assert_kind request
# shellcheck disable=SC2016
assert_body 'literal $HOME'
assert_body '--message-file /path/to/reply.txt'
if grep -Fq "<<'MSG'" "$(latest)"; then fail 'request reply command avoids heredoc'; fi
# Use the generated request id to exercise reply handling.
rid="$(sed -n 's/^request_id=//p' "$(latest | sed 's/\.msg$/.meta/')")"
tmux copy-mode -t %0
TMUX_PANE=%1 "$B/tmux-ask" --from receiver --reply --request-id "$rid" --message-file "$file" sender
assert_kind reply; assert_body 'line two'
send --notice --message-file "$file" receiver; assert_kind notice
send --any --message-file "$file" receiver; assert_kind request
if send --message-file "$file" receiver extra >"$tmp/error" 2>&1; then fail positional-conflict; fi
grep -q 'conflicts with positional message text' "$tmp/error" || fail positional-conflict-error
if send --message-file "$file" receiver '' >"$tmp/error" 2>&1; then fail empty-positional-conflict; fi
grep -q 'conflicts with positional message text' "$tmp/error" || fail empty-positional-conflict-error
if printf x | send --message-file "$file" receiver >"$tmp/error" 2>&1; then fail stdin-conflict; fi
grep -q 'conflicts with nonempty stdin' "$tmp/error" || fail stdin-conflict-error
if printf '\0' | send --message-file "$file" receiver >"$tmp/error" 2>&1; then fail nul-stdin-conflict; fi
grep -q 'conflicts with nonempty stdin' "$tmp/error" || fail nul-stdin-conflict-error
if send --message-file >"$tmp/error" 2>&1; then fail missing-path; fi
grep -q -- '--message-file needs a path' "$tmp/error" || fail missing-path-error
if send --message-file '' receiver >"$tmp/error" 2>&1; then fail empty-path; fi
grep -q -- '--message-file needs a path' "$tmp/error" || fail empty-path-error
if send --message-file '' --message-file "$file" receiver >"$tmp/error" 2>&1; then fail duplicate-empty-option; fi
grep -q 'may only be used once' "$tmp/error" || fail duplicate-empty-option-error
: > "$tmp/empty"
if send --message-file "$tmp/empty" receiver >"$tmp/error" 2>&1; then fail empty-file; fi
grep -q 'empty message' "$tmp/error" || fail empty-file-error
if send --message-file "$tmp/missing" receiver >"$tmp/error" 2>&1; then fail missing-file; fi
grep -q 'regular file' "$tmp/error" || fail missing-file-error
if send --message-file "$file" --message-file "$file" receiver >"$tmp/error" 2>&1; then fail duplicate-option; fi
grep -q 'may only be used once' "$tmp/error" || fail duplicate-option-error
ln -s "$file" "$tmp/link"
if send --message-file "$tmp/link" receiver >"$tmp/error" 2>&1; then fail symlink; fi
grep -q 'must not be a symlink' "$tmp/error" || fail symlink-error
mkdir "$tmp/dir"
if send --message-file "$tmp/dir" receiver >"$tmp/error" 2>&1; then fail nonregular; fi
grep -q 'regular file' "$tmp/error" || fail nonregular-error
head -c 1048577 /dev/zero | tr '\000' x > "$tmp/large"
if send --message-file "$tmp/large" receiver >"$tmp/error" 2>&1; then fail oversize; fi
grep -q '1048576-byte limit' "$tmp/error" || fail oversize-error
chmod 000 "$file"
if [ "$(id -u)" -ne 0 ]; then
  if send --message-file "$file" receiver >"$tmp/error" 2>&1; then fail unreadable; fi
  grep -q 'not readable' "$tmp/error" || fail unreadable-error
fi
printf 'ok: message-file request/reply/notice/any and validation cases\n'
