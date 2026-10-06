#!/usr/bin/env bash
# Stable IDs, lossless legacy migration and interruption recovery. Isolated
# server and queue only; no actual legacy queue is ever inspected or changed.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
state="$(mktemp -d "${TMPDIR:-/tmp}/agent-ids.XXXXXX")"
test_sock="agent-ids-test-$$"
other_sock="agent-ids-other-test-$$"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
. "$here/tests/helpers/cleanup.sh"
cleanup() {
  cleanup_test_server "$test_sock" || return
  cleanup_test_server "$other_sock" || return
  rm -rf "$state"
}
trap cleanup EXIT
tmux -L "$test_sock" -f /dev/null new-session -d -s test 'exec /bin/sh'
tmux -L "$test_sock" has-session || exit 1
socket="$(tmux -L "$test_sock" display-message -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe test socket' >&2; exit 1 ;; esac
export TMUX="$socket,1,0" XDG_STATE_HOME="$state/state"
tmux set-option -g default-shell /bin/sh
. "$here/bin/lib.sh"
check() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
check valid_agent_id a123456789abc
if valid_agent_id a123456789abz || valid_agent_id 123456789abcd || valid_agent_id a123; then exit 1; fi
# Source must not invoke tmux (in particular no implicit live migration).
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
( tmux() { echo 'unexpected tmux call while sourcing' >&2; exit 1; }; . "$here/bin/lib.sh" )
d="$(sessions_dir)"
q="$state/queue"
mkdir -p "$d" "$q/$test_sock" "$q/foreign"
tmux set-option -p -t %0 @agent live
tmux set-option -p -t %0 @awaiting 'child parent'
tmux set-option -p -t %0 @closed 'parent child a111111111111'
printf 'kind=codex\nid=live-conversation\ndir=/tmp/with spaces\nextra=a=b\n' > "$d/live"
printf 'kind=claude\nid=parent-conversation\nclosed=100\n' > "$d/parent"
printf 'kind=codex\nid=child-conversation\nparent=parent\nclosed=101\n' > "$d/child"
printf 'kind=claude\nid=id-shaped-conversation\nparent=child\nclosed=102\n' > "$d/a111111111111"
printf 'kind=codex\nid=orphan-conversation\nparent=missing\nclosed=103\n' > "$d/orphan"
# A replacement already written by an earlier interrupted migration can
# recover its old name mapping, even when its original filename is gone.
printf 'agent_id=a222222222222\nname=recovered\nid=recovered-conversation\nclosed=104\n' > "$d/a222222222222"
printf 'id=recovered-child-conversation\nparent=recovered\nclosed=105\n' > "$d/recovered-child"
printf 'from_name=live\nto_name=child\nkind=request\n' > "$q/$test_sock/1.meta"
printf 'body stays untouched\n' > "$q/$test_sock/1.msg"
printf 'from_name=parent\nto_name=child\nkind=reply\n' > "$q/$test_sock/2.meta"
printf 'undelivered body\n' > "$q/$test_sock/2.undelivered"
printf 'from_name=live\nto_name=parent\n' > "$q/3.meta"
printf 'from_name=live\nto_name=parent\nserver=foreign\n' > "$q/4.meta"
printf 'from_name=live\nto_name=parent\n' > "$q/foreign/5.meta"
printf 'from_name=live\nto_name=parent\nsocket=%s\n' "$socket" > "$q/6.meta"
printf 'from_name=live\nto_name=parent\nsocket=%s\n' "$other_sock" > "$q/7.meta"
mkdir "$state/flat-originals" "$state/original-records"
cp "$q"/*.meta "$state/flat-originals/"
cp "$d"/* "$state/original-records/"
# Directories are never copied recursively, including leftover partial stages.
mkdir -p "$d/nested" "$d/.pre-ids-v1.interrupted"
printf 'not a record\n' > "$d/nested/child"
printf 'partial copy\n' > "$d/.pre-ids-v1.interrupted/live"
# Interrupt backup publication after copying. No journal, records, pane
# options or queue metadata may have changed when the backup is incomplete.
mkdir -p "$state/perl"
cat > "$state/perl/InterruptBackup.pm" <<'PERL'
package InterruptBackup;
BEGIN {
  *CORE::GLOBAL::rename = sub {
    die "injected backup interruption\n" if $_[1] =~ m{/\.pre-ids-v1$};
    CORE::rename($_[0], $_[1]);
  };
}
1;
PERL
if PERL5LIB="$state/perl" PERL5OPT=-MInterruptBackup ensure_agent_ids "$q"; then
  echo 'expected backup interruption' >&2; exit 1
fi
check test ! -e "$d/.pre-ids-v1"
check test ! -e "$d/.ids-journal"
for f in "$state/original-records"/*; do check cmp "$f" "$d/${f##*/}"; done
check test -z "$(pane_agent_id %0)"
check test "$(tmux show-options -pqv -t %0 @awaiting)" = 'child parent'
for f in "$state/flat-originals"/*; do check cmp "$f" "$q/${f##*/}"; done
check test "$(wc -l < "$q/$test_sock/1.meta" | tr -d ' ')" = 3
# Never label a possibly partial old migration as an original backup.
printf '{}\n' > "$d/.ids-journal"
if ensure_agent_ids "$q"; then echo 'accepted journal without backup' >&2; exit 1; fi
check test ! -e "$d/.pre-ids-v1"
for f in "$state/original-records"/*; do check cmp "$f" "$d/${f##*/}"; done
rm "$d/.ids-journal"
# Simulate death after replacements and before final marker. A tmux shim
# fails on the first option write; subsequent replay must reuse the journal.
real_tmux="$(command -v tmux)"
mkdir -p "$state/bin"
cat > "$state/bin/tmux" <<'STUB'
#!/bin/sh
if [ "$1" = set-option ] && [ -f "$FAIL_ID_MIGRATION" ]; then
  read -r remaining < "$FAIL_ID_MIGRATION"
  [ "$remaining" -gt 0 ] || exit 91
  printf '%s\n' "$((remaining - 1))" > "$FAIL_ID_MIGRATION"
fi
exec "$REAL_TMUX" "$@"
STUB
chmod +x "$state/bin/tmux"
export REAL_TMUX="$real_tmux" FAIL_ID_MIGRATION="$state/fail"
printf '0\n' > "$FAIL_ID_MIGRATION"
# The sourced launch builder changes PATH only when called; this test never calls it.
# shellcheck disable=SC2031
if PATH="$state/bin:$PATH" ensure_agent_ids "$q"; then echo 'expected injected failure' >&2; exit 1; fi
check test ! -f "$d/.ids-v1"
check test -f "$d/.ids-journal"
check diff -r "$state/original-records" "$d/.pre-ids-v1"
parent_id="$(record_ids_by_name parent)"
child_id="$(record_ids_by_name child)"
shape_id="$(record_ids_by_name a111111111111)"
check valid_agent_id "$parent_id"
check valid_agent_id "$child_id"
check test "$shape_id" != a111111111111
check test "$(record_get "$child_id" parent)" = "$parent_id"
# A second interruption occurs after ID and awaiting were already converted.
printf '2\n' > "$FAIL_ID_MIGRATION"
# The sourced launch builder changes PATH only when called; this test never calls it.
# shellcheck disable=SC2031
if PATH="$state/bin:$PATH" ensure_agent_ids "$q"; then exit 1; fi
check test "$(tmux show-options -pqv -t %0 @awaiting)" = "$child_id $parent_id"
check test ! -f "$d/.ids-v1"
rm "$FAIL_ID_MIGRATION"
ensure_agent_ids "$q"
check test -f "$d/.ids-v1"
check test ! -f "$d/.ids-journal"
live_id="$(pane_agent_id %0)"
check valid_agent_id "$live_id"
check test "$(record_get "$live_id" id)" = live-conversation
check test "$(record_get "$live_id" extra)" = a=b
check test "$(record_get "$parent_id" id)" = parent-conversation
check test "$(record_get "$child_id" id)" = child-conversation
check test "$(record_get "$child_id" parent_name)" = parent
check test "$(record_get "$shape_id" parent)" = "$child_id"
check test "$(record_get "$shape_id" id)" = id-shaped-conversation
orphan_id="$(record_ids_by_name orphan)"
check test -z "$(record_get "$orphan_id" parent)"
check test "$(record_get "$orphan_id" parent_name)" = missing
recovered_child="$(record_ids_by_name recovered-child)"
check test "$(record_get "$recovered_child" parent)" = a222222222222
check test "$(record_get a222222222222 id)" = recovered-conversation
check test "$(tmux show-options -pqv -t %0 @awaiting)" = "$child_id $parent_id"
check test "$(closed_names %0)" = "$parent_id $child_id $shape_id"
check grep -qx "from_id=$live_id" "$q/$test_sock/1.meta"
check grep -qx "to_id=$child_id" "$q/$test_sock/1.meta"
check grep -qx "from_id=$parent_id" "$q/$test_sock/2.meta"
for f in "$state/flat-originals"/*; do check cmp "$f" "$q/${f##*/}"; done
check diff -r "$state/original-records" "$d/.pre-ids-v1"
check test "$(wc -l < "$q/4.meta" | tr -d ' ')" = 3
check test "$(wc -l < "$q/foreign/5.meta" | tr -d ' ')" = 2
check grep -qx 'body stays untouched' "$q/$test_sock/1.msg"
check grep -qx 'undelivered body' "$q/$test_sock/2.undelivered"
cp -R "$d" "$state/before-records"
cp -R "$q" "$state/before-queue"
# Marker fast path must not invoke any external command, including tmux.
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
( tmux() { return 99; }; agent_identity_lock() { return 98; }; ensure_agent_ids "$q" )
check diff -r "$state/before-records" "$d"
check diff -r "$state/before-queue" "$q"
# A second server with matching names must also leave every flat file intact,
# even files explicitly attributed to either server.
tmux -L "$other_sock" -f /dev/null new-session -d -s test 'exec /bin/sh'
tmux -L "$other_sock" has-session || exit 1
other_socket="$(tmux -L "$other_sock" display-message -p '#{socket_path}')"
case "$other_socket" in ''|*/default) echo 'unsafe second socket' >&2; exit 1 ;; esac
(
  export TMUX="$other_socket,1,0"
  tmux set-option -g default-shell /bin/sh
  tmux set-option -p -t %0 @agent live
  other_dir="$(sessions_dir)"
  mkdir -p "$other_dir" "$q/$other_sock"
  printf 'id=other-parent-conversation\n' > "$other_dir/parent"
  printf 'from_name=live\nto_name=parent\n' > "$q/$other_sock/1.meta"
  ensure_agent_ids "$q"
  check grep -q '^to_id=a' "$q/$other_sock/1.meta"
)
for f in "$state/flat-originals"/*; do check cmp "$f" "$q/${f##*/}"; done
check diff -r "$state/original-records" "$d/.pre-ids-v1"
# Renames change only the live label and own record, preserving all refs.
_rename_agent_locked %0 renamed >/dev/null
check test "$(pane_agent_id %0)" = "$live_id"
check test "$(record_get "$live_id" name)" = renamed
check grep -qx 'from_name=live' "$q/$test_sock/1.meta"
check test "$(agent_name_by_id "$live_id")" = renamed
# Closed names may be reused, without overwriting their conversations.
set_name %0 parent
check test "$(record_get "$parent_id" id)" = parent-conversation
check test "$(pane_agent_id %0)" = "$live_id"
# Reopened pane restores exactly one identity; ID theft is refused.
p="$(tmux new-window -d -P -F '#{pane_id}' -t test 'exec /bin/sh')"
check test "$(ensure_agent_id "$p" "$parent_id")" = "$parent_id"
set_name "$p" restored
check test "$(pane_agent_id "$p")" = "$parent_id"
if ensure_agent_id %0 "$parent_id" >/dev/null; then echo 'adopted another identity' >&2; exit 1; fi
add_peer %0 "$p"
case " $(closed_names %0) " in *" $parent_id "*) echo 'reopened ID remains closed' >&2; exit 1 ;; esac
note_closed "$p"
# closed record labels need not be unique.
record_set "$child_id" name parent
check test "$(record_ids_by_name parent | wc -l | tr -d ' ')" = 2
record_closed "$p"
check test -n "$(record_get "$parent_id" closed)"
# Unnamed rename and auto-name assign IDs; adopted IDs survive naming.
u="$(tmux new-window -d -P -F '#{pane_id}' -t test 'exec /bin/sh')"
_rename_agent_locked "$u" unnamed-renamed >/dev/null
check valid_agent_id "$(pane_agent_id "$u")"
v="$(tmux new-window -d -P -F '#{pane_id}' -t test 'exec /bin/sh')"
auto_name "$v" quiet >/dev/null
check valid_agent_id "$(pane_agent_id "$v")"
# A valid existing identity is safe to read inside a shared lock.
( agent_identity_lock() { return 97; }; check test "$(ensure_agent_id %0)" = "$live_id" )
echo 'ok: stable agent IDs, migration, crash recovery, metadata and rename'
