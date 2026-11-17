#!/usr/bin/env bash
# Quiet send/read flows, closed identities, archive, retention and mission logging.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; B="$here/bin"
sock="notes-$$"; tmp="$(mktemp -d "${TMPDIR:-/tmp}/notes.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0 TMUX_AGENTS_NOTES_DIGEST_SECS=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'STUB READY\n'
exec cat
STUB
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
export TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d cat
tmux -L "$sock" has-session || { echo 'ABORT: no test server'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0"
tmux set-option -g default-shell /bin/sh
tmux new-window -d "$tmp/bin/claude"
tmux new-window -d "$tmp/bin/codex"
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
tmux set -p -t %2 @agent outsider
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
. "$B/lib.sh"
. "$B/notes-lib.sh"
ensure_agent_ids "$tmp/empty"
fail() { echo "FAIL: $*" >&2; exit 1; }
for p in %1 %2; do
  ready=0
  for ((attempt=0; attempt<100; attempt++)); do
    if tmux capture-pane -p -t "$p" | grep -q 'STUB READY'; then ready=1; break; fi
    sleep .02
  done
  [ "$ready" = 1 ] || fail 'stub not ready'
done
sender="$(pane_agent_id %0)"; receiver="$(pane_agent_id %1)"; outsider="$(pane_agent_id %2)"
ask() { "$B/tmux-ask" --from sender --note "$@"; }
notes() { "$B/tmux-notes" --from receiver "$@"; }
reject() { if "$@" >"$tmp/error" 2>&1; then fail "unexpected success: $*"; fi; }
tmux set -p -t %1 @state idle
tmux set -p -t %1 @tracked 1
tmux copy-mode -t %1
ask receiver 'quiet first' >"$tmp/result"
grep -q 'noted to receiver (%1)' "$tmp/result" || fail 'send result'
[ "$(notes --count)" = 1 ] || fail 'unread count'
[ "$(tmux show-option -pqv -t %1 @state)" = idle ] || fail 'note started turn'
if tmux capture-pane -p -t %1 | grep -q 'quiet first'; then fail 'note pasted'; fi
[ -z "$(find "$(message_queue_dir)" -name '*.msg' -print 2>/dev/null || true)" ] || fail 'note queued'
note_dir="$(notes_dir)/$receiver"
cp "$note_dir"/*.json "$tmp/immutable.json"
[ "$(cat "$note_dir/.cursor")" = 0 ] || fail 'initial cursor'
notes_snapshot "$receiver" >"$tmp/hook-snapshot"
notes_summary "$receiver" receiver >"$tmp/hook-summary"
[ "$(cat "$note_dir/.cursor")" = 0 ] || fail 'hook snapshot advanced cursor'
notes --keep-unread >"$tmp/read"
[ "$(cat "$note_dir/.cursor")" = 0 ] || fail 'keep-unread advanced cursor'
grep -q 'sender:'  "$tmp/read" || fail 'sender grouping'
grep -Eq '[0-9][0-9]:[0-9][0-9] 1 \[m[0-9a-f]+\] quiet first' "$tmp/read" || fail 'time and ID'
[ "$(notes --count)" = 1 ] || fail 'keep unread'
notes >"$tmp/read"
[ "$(notes --count)" = 0 ] || fail 'read marks seen'
[ "$(cat "$note_dir/.cursor")" = 1 ] || fail 'read cursor'
cmp "$note_dir"/*.json "$tmp/immutable.json" || fail 'reading changed immutable record'
perl -MJSON::PP -0777 -ne 'my $n=decode_json($_); die if exists $n->{read_at}; die unless $n->{id} == 1 && $n->{message_id} =~ /^m/' "$tmp/immutable.json"
notes_mark_read "$receiver" 0
[ "$(cat "$note_dir/.cursor")" = 1 ] || fail 'cursor rewound'
notes --all >"$tmp/read"
grep -q 'quiet first' "$tmp/read" || fail 'all includes read'
[ "$(cat "$note_dir/.cursor")" = 1 ] || fail 'all rewound cursor'
reject ask --reply receiver conflict
reject ask --notice receiver conflict
reject ask receiver ''
reject ask outsider forbidden
ask --any outsider 'permitted'
[ "$("$B/tmux-notes" --from outsider --count)" = 1 ] || fail 'any recipient'
reject ask --any sender self
tmux set -p -t %2 @shell 1
reject ask --any outsider shell
tmux set -pu -t %2 @shell
printf 'full attachment\nsecond line\n' >"$tmp/attachment"
ask receiver --message-file "$tmp/attachment" summary
notes --keep-unread >"$tmp/read"
id="$(sed -n 's/.*tmux-read \(m[0-9a-f]*\).*/\1/p' "$tmp/read")"
[ -n "$id" ] || fail 'archive pointer'
"$B/tmux-read" "$id" >"$tmp/full"
grep -q 'second line' "$tmp/full" || fail 'archive original'
ask receiver --message-file "$tmp/attachment"
notes --keep-unread >"$tmp/read"
grep -q 'second line' "$tmp/read" || fail 'file-only full note'
now="$(date +%s)"
notes_write "$receiver" "$sender" sender m000000000001 'old but retained' "$((now - 7200))"
notes_write "$receiver" "$sender" sender m000000000002 expired "$((now - 604801))"
notes --since 10m --keep-unread >"$tmp/recent"
if grep -q 'old but retained\|expired' "$tmp/recent"; then fail 'since filter'; fi
notes --all --keep-unread >"$tmp/read"
grep -q 'old but retained' "$tmp/read" || fail 'retained old note'
expired_files=("$note_dir"/*-m000000000002.json)
[ ! -f "${expired_files[0]}" ] || fail 'seven day prune'
reject notes --since bananas
reject notes --since 1d
notes_write "$receiver" "$outsider" outsider m000000000003 'another group'
notes_summary "$receiver" receiver >"$tmp/summary"
grep -q 'tmux-notes --from receiver' "$tmp/summary" || fail 'summary read command'
grep -Eq 'latest [0-9][0-9]:[0-9][0-9]:' "$tmp/summary" || fail 'summary time'
notes_snapshot "$receiver" "$now.1" >"$tmp/snapshot"
perl -MJSON::PP -e 'local $/; my $s=decode_json(<>); die unless ref($s->{senders}) eq "ARRAY"' <"$tmp/snapshot"
# Fractional cutoffs preserve two arrivals in one second; summaries truncate
# Unicode characters rather than UTF-8 bytes and never include later lines.
notes_write a000000000010 "$sender" sender m000000000004 'before cutoff' "$now.1"
notes_write a000000000010 "$sender" sender m000000000005 'after cutoff' "$now.9"
notes_snapshot a000000000010 "$now.5" >"$tmp/fractional"
perl -MJSON::PP -e 'local $/; my $s=decode_json(<>); die unless $s->{count} == 1 && $s->{latest} eq "after cutoff"' <"$tmp/fractional"
unicode="$(perl -CS -e 'print chr(0x4e2d) x 90, "\nsecond line"')"
notes_write "$receiver" "$sender" unicode m000000000006 "$unicode"
notes_snapshot "$receiver" >"$tmp/unicode"
perl -MJSON::PP -e 'local $/; my $s=decode_json(<>); my ($g)=grep {$_->{name} eq "unicode"} @{$s->{senders}}; die unless length($g->{latest}) == 83 && $g->{latest} !~ /second/' <"$tmp/unicode"
reject notes_write "$receiver" "$sender" sender m000000000006 overwrite
notes_write "$receiver" "$sender" sender m000000000007 'parallel one' &
first_pid=$!
notes_write "$receiver" "$sender" sender m000000000008 'parallel two' &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
notes --keep-unread >"$tmp/parallel"
grep -q 'parallel one' "$tmp/parallel" || fail 'concurrent first note lost'
grep -q 'parallel two' "$tmp/parallel" || fail 'concurrent second note lost'
perl -MJSON::PP -e '
  my @ids;
  for my $path (@ARGV) {open(my $fh,"<",$path) or die $!; local $/; push @ids, decode_json(<$fh>)->{id}}
  die "concurrent IDs collided" unless $ids[0] != $ids[1];
' "$note_dir"/*-m000000000007.json "$note_dir"/*-m000000000008.json
# Retention may remove every record, but never the durable sequence or cursor.
pruned_receiver=a000000000011
notes_write "$pruned_receiver" "$sender" sender m000000000030 'expired first' "$((now - 604801))"
notes_mark_read "$pruned_receiver" 1
notes_write "$pruned_receiver" "$sender" sender m000000000031 'expired second' "$((now - 604801))"
notes_snapshot "$pruned_receiver" >"$tmp/pruned"
perl -MJSON::PP -0777 -ne 'die unless decode_json($_)->{count} == 0' "$tmp/pruned"
notes_write "$pruned_receiver" "$sender" sender m000000000032 'after all pruned'
notes_snapshot "$pruned_receiver" >"$tmp/after-prune"
perl -MJSON::PP -0777 -ne 'my $s=decode_json($_); die unless $s->{count} == 1 && $s->{latest_id} == 3' "$tmp/after-prune"
[ "$(cat "$(notes_dir)/$pruned_receiver/.cursor")" = 1 ] || fail 'pruning reset cursor'
# A closed identity remains authorized by saved ownership or historical peers.
record_set "$receiver" name receiver
record_set "$receiver" parent "$sender"
record_set "$receiver" closed "$now"
tmux kill-pane -t %1
ask receiver 'arrived while closed'
record_set "$outsider" name outsider
record_set "$outsider" closed "$now"
tmux kill-pane -t %2
reject ask outsider forbidden
ask --any outsider 'closed any'
tmux set -p -t %0 @closed "$outsider"
ask outsider 'historical peer allowed'
record_set a000000000009 name receiver
record_set a000000000009 closed "$now"
reject ask receiver ambiguous
ask "$receiver" 'closed by exact ID'
# Reopening preserves the inbox because only stable identity selects storage.
tmux new-window -d cat
pane="$(tmux list-panes -a -F '#{pane_id}' | tail -1)"
tmux set -p -t "$pane" @agent receiver
tmux set -p -t "$pane" @agent_id "$receiver"
notes --keep-unread >"$tmp/read"
grep -q 'arrived while closed' "$tmp/read" || fail 'reopened inbox'
# A PATH stub observes best-effort mission logging, including failure.
cat > "$tmp/bin/fleet-command" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$NOTES_MISSION_LOG"
exit "${NOTES_MISSION_EXIT:-0}"
STUB
chmod +x "$tmp/bin/fleet-command"
export PATH="$tmp/bin:$PATH" NOTES_MISSION_LOG="$tmp/mission"
mission_id="$("$B/tmux-agents-mission" add --from sender 'Note progress')"
ask --any --mission "$mission_id" receiver 'mission progress'
grep -qx progress "$tmp/mission" || fail 'mission kind'
grep -qx "$mission_id" "$tmp/mission" || fail 'mission ID'
export NOTES_MISSION_EXIT=1
ask --any --mission "$mission_id" receiver 'still saved' 2>"$tmp/warning"
grep -q 'mission log failed' "$tmp/warning" || fail 'mission warning'
notes --keep-unread >"$tmp/read"
grep -q 'still saved' "$tmp/read" || fail 'mission failure lost note'
notes >"$tmp/read"
[ "$(notes --count)" = 0 ] || fail 'final count'
[ -z "$(notes_summary "$receiver" receiver)" ] || fail 'empty summary'
# Delivered digests consume exactly their observed batch, including the cutoff.
notes_write "$receiver" "$sender" sender m000000000020 'included batch'
cutoff="$(notes_snapshot "$receiver" | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{latest_id}')"
notes_write "$receiver" "$sender" sender m000000000021 'later arrival' "$((now - 60))"
tmux set -p -t "$pane" @tracked 1
tmux set -p -t "$pane" @state needs_you
reject "$B/tmux-ask" --notes-digest "$pane" "$receiver" 'blocked digest' "$cutoff"
[ "$(notes --count)" = 2 ] || fail 'rejected digest marked notes read'
tmux set -p -t "$pane" @state idle
# Inject a real Enter failure after paste; nothing may become read.
real_tmux="$(command -v tmux)"
mkdir -p "$tmp/fail-bin"
cat > "$tmp/fail-bin/tmux" <<'STUB'
#!/bin/sh
if [ "$1" = send-keys ]; then exit 1; fi
exec "$NOTES_REAL_TMUX" "$@"
STUB
chmod +x "$tmp/fail-bin/tmux"
export NOTES_REAL_TMUX="$real_tmux"
reject env PATH="$tmp/fail-bin:$PATH" "$B/tmux-ask" --notes-digest "$pane" "$receiver" 'failed digest' "$cutoff"
[ "$(notes --count)" = 2 ] || fail 'failed Enter marked notes read'
sent_before="$(date +%s)"
"$B/tmux-ask" --notes-digest "$pane" "$receiver" 'successful digest' "$cutoff"
sent_at="$(tmux show-option -pqv -t "$pane" @notes_digest_sent_at)"
[ "$sent_at" -ge "$sent_before" ] && [ "$sent_at" -le "$(date +%s)" ] || fail 'digest delivery timestamp'
[ "$(notes --count)" = 1 ] || fail 'successful digest did not consume exact batch'
notes --keep-unread >"$tmp/digest-unread"
grep -q 'later arrival' "$tmp/digest-unread" || fail 'later note consumed'
if grep -q 'included batch' "$tmp/digest-unread"; then fail 'included note still unread'; fi
[ "$(tmux show-option -pqv -t "$pane" @notes_digest_at)" = "$sent_at" ] || fail 'digest timestamp'
[ "$(cat "$(notes_dir)/$receiver/.cursor")" = "$cutoff" ] || fail 'digest cursor'
notes --all --keep-unread >"$tmp/digest-all"
grep -q 'included batch' "$tmp/digest-all" || fail 'read note was removed'
# A later successful digest is permitted and consumes the next batch.
cutoff="$(notes_snapshot "$receiver" | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{latest_id}')"
"$B/tmux-ask" --notes-digest "$pane" "$receiver" 'Continuing digest' "$cutoff"
[ "$(notes --count)" = 0 ] || fail 'later digest did not consume new batch'
# Filtering advances through displayed IDs only, never an unseen higher ID.
notes_write "$receiver" "$sender" sender m000000000040 'recent displayed'
notes_write "$receiver" "$sender" sender m000000000041 'later ID outside time filter' "$((now - 7200))"
notes --since 10m >"$tmp/filtered-read"
grep -q 'recent displayed' "$tmp/filtered-read" || fail 'recent filtered note missing'
[ "$(notes --count)" = 1 ] || fail 'filtered read consumed unseen higher ID'
filtered_cursor="$(cat "$note_dir/.cursor")"
notes --all --since 10m >"$tmp/filtered-all"
[ "$(cat "$note_dir/.cursor")" = "$filtered_cursor" ] || fail 'all changed cursor beyond displayed IDs'
notes --keep-unread >"$tmp/remaining"
grep -q 'later ID outside time filter' "$tmp/remaining" || fail 'unseen note lost'
# Connected peers can exchange notes regardless of ownership or member role.
# These deliberately generic names carry no chain-role naming convention.
tmux set -p -t %0 @peers "$pane"
tmux set -p -t "$pane" @peers %0
for relationship in peer child member; do
  case "$relationship" in
    peer) tmux set -pu -t "$pane" @parent; tmux set -pu -t "$pane" @member ;;
    child) tmux set -p -t "$pane" @parent %0 ;;
    member) tmux set -p -t "$pane" @member 1 ;;
  esac
  "$B/tmux-ask" --from sender --note receiver "to $relationship"
  notes --keep-unread >"$tmp/relationship-to"
  grep -q "to $relationship" "$tmp/relationship-to" || fail "note to $relationship missing"
  "$B/tmux-ask" --from receiver --note sender "from $relationship"
  "$B/tmux-notes" --from sender >"$tmp/relationship-from"
  grep -q "from $relationship" "$tmp/relationship-from" || fail "note from $relationship missing"
done
echo 'PASS: immutable quiet notes, monotonic cursor, digest batches, retention and mission logging'
