#!/usr/bin/env bash
# Atomic request/reply publication and journal recovery at exact rename boundaries.
# REQUEST_PUBLICATION_BIN selects a frozen bin directory without changing core files.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="${REQUEST_PUBLICATION_BIN:-$here/bin}"
sock="tmux-request-publication-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-request-publication.XXXXXX")"
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE PERL5OPT PERL5LIB
export XDG_STATE_HOME="$tmp/state"
export TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
receiver="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
tmux set -p -t %0 @agent sender
tmux set -p -t %0 @tracked 1
tmux set -p -t %0 @state idle
tmux set -p -t "$receiver" @agent receiver
tmux set -p -t "$receiver" @tracked 1
tmux set -p -t "$receiver" @state idle
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
from="$(pane_agent_id %0)" to="$(pane_agent_id "$receiver")"
ledger="$XDG_STATE_HOME/tmux-agents/${S##*/}/requests"
mkdir -p "$tmp/hooks" "$tmp/tools" "$queue"
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=$((fail+1)); fi; }
# shellcheck disable=SC2329
contains() { grep -Fq -- "$2" "$1"; }
# shellcheck disable=SC2329
absent() { ! contains "$@"; }
field() { awk -F= -v key="$2" '$1==key {print substr($0,length(key)+2)}' "$1"; }
opt() { tmux show -pqv -t "$1" "@$2"; }
state() { /usr/bin/perl "$B/tmux-request-state" "$@"; }
stage() {
  local path="$1" rid="$2" kind="$3" source="$from" target="$to"
  if [ "$kind" = reply ]; then source="$to"; target="$from"; fi
  printf 'publication-body:%s:%s\n' "$rid" "$path" >"$path.tmp"
  printf 'request_id=%s\nkind=%s\nfrom_id=%s\nto_id=%s\nfrom_name=sender\nto_name=receiver\nto_pane=%s\nqueued_at=1\n' "$rid" "$kind" "$source" "$target" "$receiver" >"${path%.msg}.meta"
}
# Compile-time override delegates every real rename unchanged. It can observe
# before queue visibility or crash after a successful journal/body rename.
cat >"$tmp/hooks/PublicationHook.pm" <<'PERL'
package PublicationHook;
use strict;
use warnings;
use POSIX ();
sub readall { my ($p)=@_; open my $f,'<',$p or return ''; local $/; return <$f>; }
sub hooked_rename ($$) {
    my ($from,$to)=@_;
    my $record=$ENV{PUBLICATION_RECORD} // '';
    my $body=$ENV{PUBLICATION_BODY} // '';
    my $mode=$ENV{PUBLICATION_MODE} // '';
    if ($to eq $body && $from eq "$body.tmp") {
        my $text=readall($record);
        open my $log,'>>',$ENV{PUBLICATION_AUDIT} or die $!;
        print $log "ledger-before-body\n" if $text =~ /^request_id=/m && $text =~ /^publication=\Q$body\E$/m;
        print $log "body-hidden-before-rename\n" unless -e $body;
        close $log;
    }
    my $ok=CORE::rename($from,$to);
    if ($ok && (($mode eq 'crash-journal' && $to eq $record && readall($record) =~ /^publication=\Q$body\E$/m) ||
                ($mode eq 'crash-body' && $to eq $body))) { POSIX::_exit(91); }
    return $ok;
}
BEGIN { *CORE::GLOBAL::rename = \&hooked_rename; }
1;
PERL
hooked() {
  PUBLICATION_RECORD="$ledger/$1.record" PUBLICATION_BODY="$2" PUBLICATION_MODE="$3" PUBLICATION_AUDIT="$tmp/audit" \
    /usr/bin/perl -I"$tmp/hooks" -MPublicationHook "$B/tmux-request-state" "${@:4}"
}
r1=r000000000101
p1="$tmp/first.msg"
stage "$p1" "$r1" request
if hooked "$r1" "$p1" observe publish-create "$r1" "$from" "$to" "$p1" >"$tmp/first.log" 2>&1; then
  check 'atomic publication supported' true
else
  check 'atomic publication supported' false
  cat "$tmp/first.log"
  exit 1
fi
check 'ledger identity exists before queue visibility' contains "$tmp/audit" ledger-before-body
check 'body hidden before commit rename' contains "$tmp/audit" body-hidden-before-rename
check 'published body retains exact identity' contains "$p1" "publication-body:$r1:$p1"
check 'published metadata retains request identity' contains "${p1%.msg}.meta" "request_id=$r1"
check 'publication clears journal' absent "$ledger/$r1.record" publication=
# Two publishers race after both resolving the same pending request. No timing
# assumption: a FIFO gate releases both competitors from the same boundary.
state resolve "$to" "$from" "$r1" >"$tmp/resolve-a"
state resolve "$to" "$from" "$r1" >"$tmp/resolve-b"
a="$tmp/answer-a.msg" b="$tmp/answer-b.msg"
stage "$a" "$r1" reply
stage "$b" "$r1" reply
mkfifo "$tmp/gate-a" "$tmp/gate-b"
( IFS= read -r _ <"$tmp/gate-a"; state publish-answer "$r1" "$to" "$from" "$a" >"$tmp/a.log" 2>&1 ) & pid_a=$!
( IFS= read -r _ <"$tmp/gate-b"; state publish-answer "$r1" "$to" "$from" "$b" >"$tmp/b.log" 2>&1 ) & pid_b=$!
printf 'go\n' >"$tmp/gate-a"
printf 'go\n' >"$tmp/gate-b"
ra=0 rb=0
wait "$pid_a" || ra=$?
wait "$pid_b" || rb=$?
check 'exactly one reply publisher succeeds' test "$(( (ra==0) + (rb==0) ))" = 1
if [ "$ra" = 0 ]; then winner="$a" loser="$b"; else winner="$b" loser="$a"; fi
check 'winner publishes its own body identity' contains "$winner" "publication-body:$r1:$winner"
check 'loser never publishes its body' test ! -f "$loser"
check 'winning reply answers original request' contains "$ledger/$r1.record" status=answered
check 'reply commit clears journal' absent "$ledger/$r1.record" publication=
# Kill the ledger process precisely after the durable request journal rename,
# before activate or body publication. A later invocation must finish recovery.
r2=r000000000102
p2="$tmp/crash-create.msg"
tmux set -p -t "$receiver" @state idle
rm -f "$ledger/$to.context"
stage "$p2" "$r2" request
rc=0
hooked "$r2" "$p2" crash-journal publish-create "$r2" "$from" "$to" "$p2" >"$tmp/crash-create.log" 2>&1 || rc=$?
check 'request crash injected at journal boundary' test "$rc" = 91
check 'crashed request retains journal path' contains "$ledger/$r2.record" "publication=$p2"
check 'crashed request remains hidden' test ! -f "$p2"
state sync
check 'recovery publishes exact request body' contains "$p2" "publication-body:$r2:$p2"
check 'recovery clears request journal' absent "$ledger/$r2.record" publication=
check 'recovery activates interrupted receiver' test "$(opt "$receiver" state)" = working
check 'recovery captures completion context' test -f "$ledger/$to.context"
# Reply journal commits answered before publication. Recovery must publish its
# exact reply, and a second answer must not publish a competing body.
a2="$tmp/crash-answer.msg"
stage "$a2" "$r2" reply
rc=0
hooked "$r2" "$a2" crash-journal publish-answer "$r2" "$to" "$from" "$a2" >"$tmp/crash-answer.log" 2>&1 || rc=$?
check 'reply crash injected at journal boundary' test "$rc" = 91
check 'reply journal durably records answered' contains "$ledger/$r2.record" status=answered
check 'reply still hidden before recovery' test ! -f "$a2"
state sync
check 'recovery publishes exact reply body' contains "$a2" "publication-body:$r2:$a2"
check 'recovery clears reply journal' absent "$ledger/$r2.record" publication=
stage "$tmp/late.msg" "$r2" reply
rc=0
state publish-answer "$r2" "$to" "$from" "$tmp/late.msg" >"$tmp/late.log" 2>&1 || rc=$?
check 'recovered answer rejects competing publisher' test "$rc" != 0
check 'competing recovered answer stays hidden' test ! -f "$tmp/late.msg"
# Crash after body rename: recovery must not re-create an already consumed body.
r3=r000000000103
p3="$tmp/crash-visible.msg"
stage "$p3" "$r3" request
rc=0
hooked "$r3" "$p3" crash-body publish-create "$r3" "$from" "$to" "$p3" >"$tmp/crash-visible.log" 2>&1 || rc=$?
check 'crash after body rename injected' test "$rc" = 91
check 'body visible at post-rename crash' contains "$p3" "publication-body:$r3:$p3"
rm "$p3"
state sync
check 'recovery does not republish consumed body' test ! -f "$p3"
check 'post-rename recovery clears journal' absent "$ledger/$r3.record" publication=
state answered "$r3"
# Real queue delivery with an exact paste-buffer fault. --attempt performs only
# one synchronous attempt, so no background retry can race these assertions.
r4=r000000000104
p4="$queue/1000000000-000001-${receiver#%}.msg"
stage "$p4" "$r4" request
state publish-create "$r4" "$from" "$to" "$p4"
real_tmux="$(command -v tmux)"
cat >"$tmp/tools/tmux" <<'SHIM'
#!/bin/sh
if [ "$1" = paste-buffer ]; then
  echo 'injected paste failure' >&2
  exit 71
fi
exec "$PUBLICATION_REAL_TMUX" "$@"
SHIM
chmod +x "$tmp/tools/tmux"
rc=0
PUBLICATION_REAL_TMUX="$real_tmux" PATH="$tmp/tools:$PATH" "$B/tmux-ask" --attempt "$receiver" "$p4" 1 >"$tmp/paste.log" 2>&1 || rc=$?
check 'paste failure reached exact fault' contains "$tmp/paste.log" 'injected paste failure'
check 'failed attempt returns failure' test "$rc" != 0
check 'failed paste does not mark delivered' test -z "$(field "$ledger/$r4.record" delivered_at)"
check 'failed paste does not project overdue pending' test -z "$(opt "$receiver" request_pending_since)"
check 'failed paste retains exact retry body' contains "$p4" "publication-body:$r4:$p4"
check 'failed paste retains exact request meta' contains "${p4%.msg}.meta" "request_id=$r4"
cp "$p4" "$tmp/retry-body"
cp "${p4%.msg}.meta" "$tmp/retry-meta"
"$B/tmux-ask" --attempt "$receiver" "$p4" 1
check 'successful retry records delivery' test -n "$(field "$ledger/$r4.record" delivered_at)"
check 'successful retry projects pending delivery' test -n "$(opt "$receiver" request_pending_since)"
# Retrying an old durable body must not re-register an existing request.
state answered "$r4"
cp "$tmp/retry-body" "${p4%.msg}.undelivered"
cp "$tmp/retry-meta" "${p4%.msg}.meta"
rc=0
"$B/tmux-ask" --retry --to receiver >"$tmp/retry.log" 2>&1 || rc=$?
check 'undelivered retry accepts existing request identity' test "$rc" = 0
check 'undelivered retry does not reopen answered ledger' contains "$ledger/$r4.record" status=answered
check 'undelivered retry does not recreate overdue projection' test -z "$(opt "$receiver" request_pending_since)"
check 'undelivered retry consumes exact source' test ! -f "${p4%.msg}.undelivered"
tmux capture-pane -p -t "$receiver" >"$tmp/received"
check 'undelivered retry retains exact body identity' contains "$tmp/received" "publication-body:$r4:"
echo "$((count-fail))/$count passed"
[ "$fail" -eq 0 ]
