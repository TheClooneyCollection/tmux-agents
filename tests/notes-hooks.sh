#!/usr/bin/env bash
# Quiet note summaries and independent idle digests, with cat stand-ins only.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-notes-hooks-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-notes-hooks.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_IDLE_SECS=0 TMUX_AGENTS_NOTES_DIGEST_SECS=0
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -x 240 -y 60 'stty -echo; exec cat'
tmux -L "$sock" has-session
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -g @tmux_agents_chip_fps 1
tmux split-window -d 'stty -echo; exec cat'
tmux set -p -t %0 @agent main
tmux set -p -t %1 @agent helper
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
. "$B/lib.sh"
. "$B/notes-lib.sh"
ensure_agent_ids
id="$(pane_agent_id %0)" helper_id="$(pane_agent_id %1)"
record_set "$id" kind claude
record_set "$helper_id" kind codex
tmux set -p -t %0 @tracked 1
tmux set -p -t %0 @state idle
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=$((fail+1)); fi; }
option() { tmux show-option -pqv -t %0 "$1"; }
# shellcheck disable=SC2329
wait_marker() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [ -n "$(option @notes_digest_at)" ] && return 0
    sleep .05
  done
  return 1
}
idle() {
  tmux set -p -t %0 @state idle
  tmux set -p -t %0 @notes_idle_since "$(($(date +%s)-5))"
}
write_note() { notes_write "$id" "$helper_id" helper "$(new_message_id)" "$1"; }
once() { TMUX_AGENTS_NOTES_DIGEST_SECS=1 "$B/tmux-agents-notes-digest.sh" --once "$id"; }
start() { printf '{"prompt":"hello"}' | "$B/tmux-agent-report" --pane %0 --turn-start; }
check 'empty Claude hook emits nothing' test -z "$(start)"
write_note 'build progress'
start >"$tmp/hook"
# shellcheck disable=SC2016
check 'Claude hook emits additionalContext' perl -MJSON::PP -0777 -ne 'my $j=decode_json($_); exit !($j->{hookSpecificOutput}{hookEventName} eq "UserPromptSubmit" && $j->{hookSpecificOutput}{additionalContext}=~/build progress/ && $j->{hookSpecificOutput}{additionalContext}=~/tmux-notes --from main/)' "$tmp/hook"
check 'hook leaves cursor untouched' test "$(cat "$(notes_dir)/$id/.cursor" 2>/dev/null || printf 0)" = 0
check 'summary leaves note unread' test "$("$B/tmux-notes" --from main --count)" = 1
record_set "$id" kind codex
check 'Codex turn-start emits no Claude context' test -z "$(start)"
record_set "$id" kind claude
"$B/tmux-notes" --from main >/dev/null
check 'reading suppresses subsequent hook summary' test -z "$(start)"
write_note 'digest payload'
# The internal timer is exercised synchronously for blocked states.
tmux set -p -t %0 @state working
once
check 'working receiver gets no digest' test -z "$(option @notes_digest_at)"
tmux set -p -t %0 @state needs_you
once
check 'needs-you receiver gets no digest' test -z "$(option @notes_digest_at)"
idle
tmux set -p -t %0 @perm_since 123
once
check 'permission receiver gets no digest' test -z "$(option @notes_digest_at)"
tmux set -pu -t %0 @perm_since
tmux copy-mode -t %0
once
check 'copy-mode receiver gets no digest' test -z "$(option @notes_digest_at)"
tmux send-keys -t %0 -X cancel
"$B/tmux-agents-notes-digest.sh" --once "$id"
check 'zero setting disables digest' test -z "$(option @notes_digest_at)"
tmux set -p -t %0 @notes_idle_since "$(date +%s)"
TMUX_AGENTS_NOTES_DIGEST_SECS=300 "$B/tmux-agents-notes-digest.sh" --once "$id"
check 'idle interval must elapse' test -z "$(option @notes_digest_at)"
idle
# Public write starts the observer, without any chip daemon or foreground poll.
TMUX_AGENTS_NOTES_DIGEST_SECS=1 "$B/tmux-ask" --from helper --note main 'automatic digest payload' >/dev/null
check 'public note starts independent digest observer' wait_marker
stamp="$(cat "$(notes_dir)/$id/.cursor")"
check 'digest starts a Codex notice turn without debt' test -z "$(option @owed)"
check 'digest marks included notes read' test "$("$B/tmux-notes" --from main --count)" = 0
tmux capture-pane -p -S - -t %0 >"$tmp/screen"
check 'digest includes sender and latest payload' grep -q 'helper (2): automatic digest payload' "$tmp/screen"
digest_before="$(option @notes_digest_at)"
notice_hook="$(printf '%s' '{"prompt":"[notice from tmux-agents to main via tmux-ask]\ndigest\n[end of notice from tmux-agents to main]"}' | "$B/tmux-agent-report" --pane %0 --turn-start)"
check 'notice hook does not repeat digested notes' test -z "$notice_hook"
check 'digest notice hook preserves continuation marker' test "$(option @notes_digest_at)" = "$digest_before"
turn_begin %0 notice delivery
check 'notice delivery preserves continuation marker' test "$(option @notes_digest_at)" = "$digest_before"
idle
once
check 'no new notes means no digest' test "$(cat "$(notes_dir)/$id/.cursor")" = "$stamp"
write_note 'later batch'
TMUX_AGENTS_NOTES_DIGEST_SECS=300 "$B/tmux-agents-notes-digest.sh" --once "$id"
check 'new notes wait another full interval' test "$(cat "$(notes_dir)/$id/.cursor")" = "$stamp"
check 'pending next batch stays unread' test "$("$B/tmux-notes" --from main --count)" = 1
# Advance recorded idle timestamps, not a sleep or probabilistic rerun.
tmux set -p -t %0 @notes_digest_sent_at "$(($(date +%s)-5))"
idle
tmux clear-history -t %0
tmux send-keys -t %0 C-l
once
check 'next interval sends only a new batch' test "$(cat "$(notes_dir)/$id/.cursor")" != "$stamp"
tmux capture-pane -p -S - -t %0 >"$tmp/screen"
check 'later digest carries continuation prefix' grep -q 'Continuing from last update' "$tmp/screen"
check 'later digest contains only its one new note' grep -q '1 agent notes.*helper (1): later batch' "$tmp/screen"
check 'later digest marks its note read' test "$("$B/tmux-notes" --from main --count)" = 0
stamp="$(cat "$(notes_dir)/$id/.cursor")"
tmux set -p -t %0 @notes_digest_sent_at "$(($(date +%s)-5))"
idle
once
check 'no new batch cannot digest again' test "$(cat "$(notes_dir)/$id/.cursor")" = "$stamp"
# A genuine Claude user prompt ends the uninterrupted update sequence.
check 'user hook does not repeat digested notes' test -z "$(start)"
check 'user prompt clears continuation marker' test -z "$(option @notes_digest_at)"
"$B/tmux-agent-report" --pane %0 --turn-end >/dev/null
write_note 'fresh after user prompt'
fresh_idle="$(($(date +%s)-125))"
tmux set -p -t %0 @notes_idle_since "$fresh_idle"
tmux set -p -t %0 @notes_digest_sent_at "$((fresh_idle-600))"
expected_since="$(perl -e 'my @t=localtime($ARGV[0]); printf "%02d:%02d",$t[2],$t[1]' "$fresh_idle")"
once
tmux capture-pane -p -S - -t %0 >"$tmp/screen"
grep 'fresh after user prompt' "$tmp/screen" >"$tmp/fresh-digest"
check 'post-user digest uses idle start for since' grep -Fq "agent notes since $expected_since:" "$tmp/fresh-digest"
check 'post-user digest starts a fresh update' test "$(grep -c 'Continuing from last update' "$tmp/fresh-digest" || true)" = 0
check 'post-user digest consumes its batch' test "$("$B/tmux-notes" --from main --count)" = 0
# Codex direct-input evidence resets even when the latest delivery is stale.
record_set "$id" kind codex
record_set "$id" id notes-user-thread
tmux set -p -t %0 @codex_thread notes-user-thread
tmux set -p -t %0 @last_delivered m111111111111
tmux set -p -t %0 @state working
codex_notify() {
  "$B/tmux-agent-report" --agent-id "$id" --codex-notify "$1"
}
marker="$(option @notes_digest_at)"
codex_notify '{"type":"agent-turn-complete","thread-id":"notes-user-thread","input-messages":["[notice from tmux-agents to main via tmux-ask · m222222222222]\nold digest"]}'
check 'late old-header notify preserves continuation' test "$(option @notes_digest_at)" = "$marker"
codex_notify '{"type":"agent-turn-complete","thread-id":"notes-user-thread"}'
check 'notify without input array preserves continuation' test "$(option @notes_digest_at)" = "$marker"
tmux set -p -t %0 @state working
before_user="$(date +%s)"
codex_notify '{"type":"agent-turn-complete","thread-id":"notes-user-thread","input-messages":["user typed a question"]}'
check 'Codex direct-input notify resets before stale guard' test -z "$(option @notes_digest_at)"
check 'direct-input reset leaves stale state guard intact' test "$(option @state)" = working
check 'direct-input reset preserves latest delivery token' test "$(option @last_delivered)" = m111111111111
check 'direct-input notify records new idle origin' test "$(option @notes_idle_since)" -ge "$before_user"
write_note 'fresh after Codex user input'
tmux set -p -t %0 @state idle
fresh_idle="$(($(date +%s)-125))"
tmux set -p -t %0 @notes_idle_since "$fresh_idle"
tmux set -p -t %0 @notes_digest_sent_at "$((fresh_idle-600))"
expected_since="$(perl -e 'my @t=localtime($ARGV[0]); printf "%02d:%02d",$t[2],$t[1]' "$fresh_idle")"
once
tmux capture-pane -p -S - -t %0 >"$tmp/screen"
grep 'fresh after Codex user input' "$tmp/screen" >"$tmp/codex-fresh-digest"
check 'post-Codex-user digest uses new idle start' grep -Fq "agent notes since $expected_since:" "$tmp/codex-fresh-digest"
check 'post-Codex-user digest has no continuation prefix' test "$(grep -c 'Continuing from last update' "$tmp/codex-fresh-digest" || true)" = 0
marker="$(option @notes_digest_at)"
"$B/tmux-agent-report" --agent-id aeeeeeeeeeeee --codex-notify '{"type":"agent-turn-complete","thread-id":"notes-user-thread","input-messages":[]}'
check 'invalid live identity cannot reset continuation' test "$(option @notes_digest_at)" = "$marker"
printf '%s checks, %s failures\n' "$count" "$fail"
[ "$fail" = 0 ]
