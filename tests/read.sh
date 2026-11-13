#!/usr/bin/env bash
# Retained message IDs, pointer delivery, exact bodies, retention and offline reads.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-read-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-read.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -x 180 -y 50 cat
tmux -L "$sock" has-session || { echo 'ABORT: no test server'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0"
tmux set-option -g default-shell /bin/sh
tmux new-window -d cat
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
Q="/tmp/tmux-agents-$(id -u)/queue/$sock"
fail() { echo "FAIL: $*" >&2; exit 1; }
# PID ordering can wrap within one second. Identify this send's queue entry,
# then assert on its body and metadata, never on filename ordering.
send() {
  local before=" " candidate
  for candidate in "$Q"/*.msg; do
    [ -f "$candidate" ] || continue
    before="$before$candidate "
  done
  "$@"
  last_file=""
  for candidate in "$Q"/*.msg; do
    [ -f "$candidate" ] || continue
    case "$before" in *" $candidate "*) continue ;; esac
    [ -z "$last_file" ] || fail 'multiple messages published by one send'
    last_file="$candidate"
  done
  [ -n "$last_file" ] && [ -f "${last_file%.msg}.meta" ] || fail 'message and metadata not published'
}
ask() { send "$B/tmux-ask" --from sender receiver "$@"; }
latest() { printf '%s\n' "$last_file"; }
pointer() { sed -n 's/^Read the full message here: tmux-read //p' "$1"; }
has() { grep -Fq -- "$2" "$1" || fail "missing $2"; }
tmux copy-mode -t %1
cat > "$tmp/long" <<'BODY'
Summary of the work.
A second summary line.

literal $HOME `not executed`
detail two
detail three
detail four
BODY
# Ordinary arguments, stdin, files and system notices paste in full, no archive.
ask --notice "$(cat "$tmp/long")"
has "$(latest)" 'detail four'
[ -z "$(pointer "$(latest)")" ] || fail 'plain argument pointer'
ask --notice < "$tmp/long"
has "$(latest)" 'detail four'
[ -z "$(pointer "$(latest)")" ] || fail 'stdin pointer'
printf 'ignored stdin' | "$B/tmux-ask" --from sender --notice --message-file "$tmp/long" receiver
ask --notice --message-file "$tmp/long"
has "$(latest)" 'detail four'
[ -z "$(pointer "$(latest)")" ] || fail 'file-only pointer'
send "$B/tmux-ask" --system-notice %1 "$(cat "$tmp/long")"
has "$(latest)" 'detail four'
[ -z "$(pointer "$(latest)")" ] || fail 'system notice pointer'
[ ! -d "$XDG_STATE_HOME/tmux-agents/$sock/messages" ] || fail 'ordinary messages archived'

# Explicit summaries are retained verbatim, even across paragraphs and >5 lines.
summary='Review completed.

First finding
Second finding
Third finding
Fourth finding
Fifth finding'
ask --message-file "$tmp/long" "$summary"
f="$(latest)"
rid="$(pointer "$f")"
[ -n "$rid" ] || fail pointer
has "${f%.msg}.meta" "request_id=$rid"
has "$f" '[request from sender to receiver via tmux-ask]'
has "$f" '[end of request from sender to receiver]'
has "$f" "--request-id $rid"
has "$f" "$summary"
if grep -q 'detail two' "$f"; then fail 'attached details pasted'; fi
"$B/tmux-read" "$rid" > "$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'message-file original'
# The source may disappear after send; the stored copy survives delivery.
cp "$tmp/long" "$tmp/expected"
rm "$tmp/long"
tmux send-keys -t %1 -X cancel
"$B/tmux-ask" --kick %1
"$B/tmux-read" "$rid" > "$tmp/read"
cmp "$tmp/read" "$tmp/expected" || fail 'original after delivery'
cp "$tmp/expected" "$tmp/long"
tmux copy-mode -t %1
ask --notice --message-file "$tmp/long" 'Notice summary.'
nid="$(pointer "$(latest)")"
case "$nid" in m????????????) ;; *) fail 'notice ID' ;; esac
[ "$nid" != "$rid" ] || fail 'unique notice ID'
"$B/tmux-read" "$nid" > "$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'notice original'
tmux copy-mode -t %0
send "$B/tmux-ask" --from receiver --reply --request-id "$rid" --message-file "$tmp/long" sender 'Reply summary.'
replyid="$(pointer "$(latest)")"
case "$replyid" in m????????????) ;; *) fail 'reply ID' ;; esac
[ "$replyid" != "$rid" ] && [ "$replyid" != "$nid" ] || fail 'unique reply ID'
"$B/tmux-read" "$replyid" > "$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'reply original'
# Even a tiny file is archived when explicitly combined with a summary.
printf 'one line without final newline' > "$tmp/tiny"
ask --notice --message-file "$tmp/tiny" 'Tiny attachment.'
tinyid="$(pointer "$(latest)")"
[ -n "$tinyid" ] || fail 'explicit short attachment'
"$B/tmux-read" "$tinyid" > "$tmp/read"
cmp "$tmp/read" "$tmp/tiny" || fail 'unterminated original'
if "$B/tmux-ask" --from sender receiver --message-file "$tmp/tiny" '' >"$tmp/error" 2>&1; then fail 'empty summary'; fi
has "$tmp/error" 'empty message'
# Reads are socket-free and do not need the original sending/receiving agent.
mkdir "$tmp/stubs"
printf '#!/bin/sh\necho unexpected-tmux >&2\nexit 99\n' > "$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
PATH="$tmp/stubs:$PATH" "$B/tmux-read" "$rid" > "$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'offline read'
TMUX="/tmp/another-read-socket,1,0" "$B/tmux-read" "$rid" >"$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'cross socket read'
env -u TMUX -u TMUX_PANE "$B/tmux-read" "$rid" >"$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'plain shell read'
for bad in '../escape' mffffffffffff ''; do
  if "$B/tmux-read" "$bad" >"$tmp/error" 2>&1; then fail "accepted $bad"; fi
done
# A duplicate ID is refused rather than silently choosing another original.
mkdir -p "$XDG_STATE_HOME/tmux-agents/duplicate/messages"
cp "$XDG_STATE_HOME/tmux-agents/$sock/messages/$rid.txt" "$XDG_STATE_HOME/tmux-agents/duplicate/messages/$rid.txt"
if "$B/tmux-read" "$rid" >"$tmp/error" 2>&1; then fail 'ambiguous ID accepted'; fi
has "$tmp/error" 'ambiguous across sockets'
rm "$XDG_STATE_HOME/tmux-agents/duplicate/messages/$rid.txt"
# Age just one original; a read prunes it without affecting newer originals.
old="$XDG_STATE_HOME/tmux-agents/$sock/messages/$nid.txt"
perl -e 'utime(time-8*86400,time-8*86400,$ARGV[0]) or die $!' "$old"
if "$B/tmux-read" "$nid" >"$tmp/error" 2>&1; then fail 'expired read'; fi
has "$tmp/error" 'pruned after 7 days'
[ ! -e "$old" ] || fail 'expired original retained'
"$B/tmux-read" "$rid" > "$tmp/read"
cmp "$tmp/read" "$tmp/long" || fail 'recent original pruned'
echo 'PASS: retained messages, pointers, exact originals and socket-free reads'
