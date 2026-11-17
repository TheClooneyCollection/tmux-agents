#!/usr/bin/env bash
# Summary archives, nameless replies, mission logs and literal Codex argv.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; B="$here/bin"
sock="ask-streamlined-$$"; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ask-streamlined.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0 TMUX_AGENTS_NOTES_DIGEST_SECS=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() { if "$@" >"$tmp/error" 2>&1; then fail "unexpected success: $*"; fi; }
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'STUB READY\n'
exec cat
STUB
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
export PATH="$tmp/bin:$PATH" TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d cat
tmux -L "$sock" has-session || fail 'no test server'
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) fail 'unsafe socket' ;; esac
export TMUX="$S,1,0"
tmux set-option -g default-shell /bin/sh
tmux new-window -d "$tmp/bin/claude"
tmux new-window -d "$tmp/bin/codex"
for p in %1 %2; do
  ready=0
  for ((attempt=0; attempt<100; attempt++)); do
    if tmux capture-pane -p -t "$p" | grep -q 'STUB READY'; then ready=1; break; fi
    sleep .02
  done
  [ "$ready" = 1 ] || fail "stub not ready: $p"
done
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent receiver
tmux set -p -t %2 @agent other
tmux set -p -t %0 @peers '%1 %2'
tmux set -p -t %1 @peers '%0 %2'
tmux set -p -t %2 @peers '%0 %1'
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty"
ask() { "$B/tmux-ask" --from sender "$@"; }
reply() { "$B/tmux-ask" --from receiver --reply "$@"; }
# A lone reply argument without stdin explains both unambiguous forms.
reject reply 'one positional body' </dev/null
grep -Fq -- '--reply -- "text" or --reply NAME "text"' "$tmp/error" || fail 'ambiguous reply guidance'
# A receiver with no requests cannot guess where to reply.
reject reply -- 'no requester'
grep -q 'no remembered requester' "$tmp/error" || fail 'missing requester error'
# Actual delivered requests remember the latest sender, including top-level agents.
ask receiver 'first request'
"$B/tmux-ask" --from other receiver 'second request'
tmux copy-mode -t %2
reply -- 'nameless positional reply'
Q="$(message_queue_dir)"
find_message() {
  local f
  for f in "$Q"/*.msg; do
    [ -f "$f" ] || continue
    if grep -Fq -- "$1" "$f"; then
      [ -f "${f%.msg}.meta" ] || fail 'missing metadata'
      printf '%s\n' "$f"; return 0
    fi
  done
  fail "missing queued body: $1"
}
f="$(find_message 'nameless positional reply')"
grep -q '^to_name=other$' "${f%.msg}.meta" || fail 'reply did not choose latest requester'
printf '%s' 'nameless stdin reply' | reply
f="$(find_message 'nameless stdin reply')"
grep -q '^kind=reply$' "${f%.msg}.meta" || fail 'stdin reply kind'
# Renaming the requester keeps stable identity routing.
tmux set -p -t %2 @agent renamed
reply -- 'reply after rename'
f="$(find_message 'reply after rename')"
grep -q '^to_name=renamed$' "${f%.msg}.meta" || fail 'reply did not follow rename'
# Named replies remain available when the remembered requester differs.
tmux copy-mode -t %0
reply sender 'explicit named reply'
f="$(find_message 'explicit named reply')"
grep -q '^to_name=sender$' "${f%.msg}.meta" || fail 'named reply target'
# Notices do not replace the requester; connection authorization still applies.
ask --notice receiver 'notice does not replace requester'
reply -- 'reply after notice'
f="$(find_message 'reply after notice')"
grep -q '^to_name=renamed$' "${f%.msg}.meta" || fail 'notice changed requester'
tmux set -p -t %1 @peers %0
reject reply -- 'not connected'
grep -q 'not connected' "$tmp/error" || fail 'reply bypassed peer guard'
reply --any -- 'authorized unrelated reply'
f="$(find_message 'authorized unrelated reply')"
grep -q '^to_name=renamed$' "${f%.msg}.meta" || fail 'any reply target'
tmux kill-pane -t %2
reject reply -- 'closed requester'
grep -q 'unavailable' "$tmp/error" || fail 'closed requester error'
# Summary delivery contains only the short text and archive pointer.
tmux copy-mode -t %1
body=$'retained detail one\nretained detail two'
ask --summary 'short positional summary' receiver "$body"
f="$(find_message 'short positional summary')"
if grep -q 'retained detail' "$f"; then fail 'full body leaked into summary'; fi
id="$(sed -n 's/^Read the full message here: tmux-read //p' "$f")"
[ "$("$B/tmux-read" "$id")" = "$body" ] || fail 'positional archive differs'
printf '%s\n\n' "$body" >"$tmp/stdin-body"
ask --summary 'short stdin summary' receiver <"$tmp/stdin-body"
f="$(find_message 'short stdin summary')"
id="$(sed -n 's/^Read the full message here: tmux-read //p' "$f")"
[ "$("$B/tmux-read" "$id")" = "$body" ] || fail 'stdin archive differs'
cmp "$tmp/stdin-body" "$(messages_dir)/$id.txt" || fail 'stdin trailing newlines lost'
ask --notice --summary 'notice summary' receiver "$body"
f="$(find_message 'notice summary')"
grep -q '^kind=notice$' "${f%.msg}.meta" || fail 'summary notice kind'
reply --summary 'reply summary' sender "$body"
f="$(find_message 'reply summary')"
grep -q '^kind=reply$' "${f%.msg}.meta" || fail 'summary reply kind'
reject ask receiver --summary
grep -q -- '--summary needs text' "$tmp/error" || fail 'missing summary error'
reject ask receiver --summary '' "$body"
reject ask receiver --summary short --summary duplicate "$body"
grep -q 'only be used once' "$tmp/error" || fail 'duplicate summary error'
reject ask receiver --summary short --message-file "$tmp/missing" "$body"
grep -q 'conflicts' "$tmp/error" || fail 'file conflict error'
reject ask receiver --summary short </dev/null
grep -q 'empty message' "$tmp/error" || fail 'empty body error'
# One quoted multi-line positional argument keeps shell syntax literal. Verify
# the checked-in rules accept the exact argv prefix without running an agent.
export PATH="$B:$PATH"
python3 - "$here" "$tmp" <<'PY'
import pathlib, shlex, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
body = '\n'.join(f"line {n}: 'single' \"double\" `touch NEVER` $(touch NEVER) $HOME \\literal" for n in range(100))
argv = ['tmux-ask', '--from', 'sender', 'receiver', body]
rules = []
def prefix_rule(**rule):
    rules.append(rule)
exec((root / 'integrations/codex/tmux-agents.rules').read_text(), {'prefix_rule': prefix_rule})
assert any(r['decision'] == 'allow' and argv[:len(r['pattern'])] == r['pattern'] for r in rules)
(tmp / 'long-body').write_text(body)
(tmp / 'send-long.sh').write_text(shlex.join(argv) + '\n')
PY
/bin/bash "$tmp/send-long.sh"
f="$(find_message 'line 99:')"
python3 - "$tmp/long-body" "$f" <<'PY'
import pathlib, sys
body, received = (pathlib.Path(p).read_text() for p in sys.argv[1:])
assert received.split('\n', 1)[1].split('\n\n(You are ', 1)[0] == body
PY
[ ! -e NEVER ] || fail 'literal shell text executed'
# Local mission log failures do not publish a note/report.
mission="$("$B/tmux-agents-mission" add --from sender 'Messaging flow')"
ask --note --mission "$mission" receiver $'progress line one\nline two'
"$B/tmux-agents-mission" show --from sender "$mission" >"$tmp/mission"
grep -q $'sender\tprogress\tprogress line one line two' "$tmp/mission" || fail 'local note log'
ask --note --mission "$mission" --summary 'mission summary' receiver "$body"
"$B/tmux-notes" --from receiver --keep-unread >"$tmp/notes"
grep -q 'mission summary' "$tmp/notes" || fail 'summary note missing'
if grep -q 'retained detail' "$tmp/notes"; then fail 'note leaked full body'; fi
report='A full mission report longer than the sixty characters shown in the activity chip.'
"$B/tmux-agent-report" --from sender --mission "$mission" "$report"
"$B/tmux-agents-mission" show --from sender "$mission" >"$tmp/mission"
grep -Fq "$report" "$tmp/mission" || fail 'report log truncated'
[ "$(tmux show-option -pqv -t %0 @activity)" = "${report:0:60}" ] || fail 'report chip changed'
archives_before="$(find "$(messages_dir)" -type f -print | sort)"
reject ask --note --mission M999 --summary 'invalid mission summary' receiver 'invalid mission note'
grep -q "cannot read mission 'M999'; note was not saved" "$tmp/error" || fail 'mission preflight error'
[ "$archives_before" = "$(find "$(messages_dir)" -type f -print | sort)" ] || fail 'invalid mission retained attachment'
mission_before="$("$B/tmux-agents-mission" show --from sender "$mission")"
mkdir "$(mission_directory)/.lock"
reject ask --note --mission "$mission" --summary 'locked mission summary' receiver 'locked mission note'
rmdir "$(mission_directory)/.lock"
grep -q "cannot log mission '$mission'; note was not saved" "$tmp/error" || fail 'locked mission error'
[ "$archives_before" = "$(find "$(messages_dir)" -type f -print | sort)" ] || fail 'failed mission retained attachment'
[ "$mission_before" = "$("$B/tmux-agents-mission" show --from sender "$mission")" ] || fail 'failed mission changed log'
reject "$B/tmux-agent-report" --from sender --mission M999 'invalid mission report'
[ "$(tmux show-option -pqv -t %0 @activity)" = "${report:0:60}" ] || fail 'invalid mission changed report'
"$B/tmux-notes" --from receiver --keep-unread >"$tmp/notes"
if grep -Eq 'invalid mission|locked mission' "$tmp/notes"; then fail 'invalid mission published note'; fi
reject "$B/tmux-agent-report" --from sender --mission "$mission" --turn-end
# Reusing a cleared pane must not inherit the previous agent's requester.
clear_agent %1
[ -z "$(tmux show-option -pqv -t %1 @last_requester)" ] || fail 'cleared pane retained requester'
printf 'PASS: summaries, nameless replies, literal positional body and local mission logs\n'
