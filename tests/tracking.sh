#!/usr/bin/env bash
# Hook opt-in, untracked legacy state, request/retry semantics and UI consistency.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-tracking-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-tracking.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s tracking cat </dev/null
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux split-window cat
TMUX_PANE=%0 "$B/tmux-connect" %1 --as boss <<< legacy >/dev/null
tmux set -p -t %1 @parent %0
. "$B/lib.sh"
opt() { tmux show -pqv -t %1 "@$1"; }
rows() { FZF_PROMPT='all · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' | sed $'s/\033\\[[0-9;]*m//g'; }
for state in working needs_you "done"; do
  tmux set -p -t %1 @state "$state"
  tmux set -p -t %1 @state_since 1
  tmux set -p -t %1 @worked 99999
  tmux set -p -t %1 @turn_start 1
  tmux set -p -t %1 @attention_since 1
  rows >"$tmp/rows"
  grep -Eq 'legacy +- +boss' "$tmp/rows" || { cat "$tmp/rows"; exit 1; }
  if grep -Eq 'worked|needs you|working|✓ done' "$tmp/rows"; then exit 1; fi
  "$B/tmux-agents" --preview-info %1 >"$tmp/preview"
  grep -q 'tracking -' "$tmp/preview"
  if grep -q 'worked' "$tmp/preview"; then exit 1; fi
  "$B/tmux-agents" --chip >"$tmp/chip"
  if grep -Eq 'NEEDS YOU|⠿|✓|starting' "$tmp/chip"; then exit 1; fi
done
echo 'ok    untracked legacy state and worked time hidden in list, preview and chip'
# Overlay attention remains useful even without turn hooks.
tmux set -p -t %1 @perm_since 1
rows >"$tmp/rows"
grep -q '⚠ permission' "$tmp/rows" || { cat "$tmp/rows"; exit 1; }
tmux set -pu -t %1 @perm_since
tmux set -p -t %1 @msg_waiting_since 1
rows >"$tmp/rows"
grep -q '✉ message waiting' "$tmp/rows"
tmux set -pu -t %1 @msg_waiting_since
# A request preserves state and tracking but still clears explicit waiting.
tmux set -p -t %1 @state idle
tmux set -p -t %1 @waiting_on background
"$B/tmux-ask" --from boss legacy 'untracked request' >/dev/null
[ "$(opt state)" = idle ]
[ -z "$(opt tracked)" ]
[ -z "$(opt waiting_on)" ]
[ -z "$(opt attention_since)" ]
[ -n "$(tmux show -pqv -t %0 @awaiting)" ]
echo 'ok    request does not start untracked receiver and preserves wait bookkeeping'
# Retrying a retained request follows the same opt-in rule.
q="/tmp/tmux-agents-$(id -u)/queue/$sock"
mkdir -p "$q"
for tracked in 0 1; do
  tmux set -p -t %1 @tracked "$tracked"
  tmux set -p -t %1 @state idle
  tmux set -p -t %1 @waiting_on background
  stem="$q/$(date +%s)-$$-retry-$tracked"
  printf '[request from boss to legacy via tmux-ask]\nretry-%s\n' "$tracked" >"$stem.undelivered"
  printf 'from_id=%s\nto_id=%s\nkind=request\n' "$(pane_agent_id %0)" "$(pane_agent_id %1)" >"$stem.meta"
  "$B/tmux-ask" --retry --to legacy </dev/null >/dev/null
  [ ! -f "$stem.undelivered" ]
  [ -z "$(opt waiting_on)" ]
  if [ "$tracked" = 1 ]; then [ "$(opt state)" = working ]; else [ "$(opt state)" = idle ]; fi
done
echo 'ok    retained request retry starts only tracked receivers'

# Each supported turn callback independently upgrades an existing pane.
for hook in start end notify; do
  tmux set -pu -t %1 @tracked
  tmux set -p -t %1 @state idle
  case "$hook" in
    start) "$B/tmux-agent-report" --pane %1 --turn-start </dev/null ;;
    end) "$B/tmux-agent-report" --pane %1 --turn-end </dev/null ;;
    notify) "$B/tmux-agent-report" --codex-notify '{"type":"agent-turn-complete","thread-id":"tracking-thread","input-messages":["[request from boss to legacy via tmux-ask] task"],"last-assistant-message":"done"}' ;;
  esac
  [ "$(opt tracked)" = 1 ]
done
tmux set -p -t %1 @state idle
"$B/tmux-ask" --from boss legacy 'tracked request' >/dev/null
[ "$(opt state)" = working ]
rows >"$tmp/rows"
grep -q '⠿ working' "$tmp/rows"
echo 'ok    first turn-start, turn-end or Codex notify enables tracking'
# A launcher first turn has ordinary input, not tmux-ask routing text.
plain="$(tmux new-window -d -P -F '#{pane_id}' cat)"
tmux set -p -t "$plain" @agent plain-codex
plain_id="$(ensure_agent_id "$plain")"
record_set "$plain_id" kind codex
record_set "$plain_id" launcher 1
tmux set -p -t "$plain" @state working
plain_json='{"type":"agent-turn-complete","thread-id":"plain-thread","input-messages":["hello"],"last-assistant-message":"hello back"}'
"$B/tmux-agent-report" --agent-id "$plain_id" --codex-notify "$plain_json"
[ "$(tmux show -pqv -t "$plain" @tracked)" = 1 ]
[ "$(tmux show -pqv -t "$plain" @state)" = needs_you ]
[ "$(record_get "$plain_id" id)" = plain-thread ]
# A side-thread title and a different conversation cannot replace the binding.
"$B/tmux-agent-report" --agent-id "$plain_id" --codex-notify '{"type":"agent-turn-complete","thread-id":"side-thread","last-assistant-message":"{\"title\":\"Title\"}"}'
"$B/tmux-agent-report" --agent-id "$plain_id" --codex-notify '{"type":"agent-turn-complete","thread-id":"wrong-thread","last-assistant-message":"done"}'
[ "$(tmux show -pqv -t "$plain" @codex_thread)" = plain-thread ]
# Same pane and label, different stable identity: a late callback stays inert.
tmux set -pu -t "$plain" @agent_id
tmux set -pu -t "$plain" @codex_thread
tmux set -pu -t "$plain" @tracked
tmux set -p -t "$plain" @state idle
replacement_id="$(ensure_agent_id "$plain")"
[ "$replacement_id" != "$plain_id" ]
"$B/tmux-agent-report" --agent-id "$plain_id" --codex-notify "$plain_json"
[ -z "$(tmux show -pqv -t "$plain" @codex_thread)" ]
[ -z "$(tmux show -pqv -t "$plain" @tracked)" ]
[ "$(tmux show -pqv -t "$plain" @state)" = idle ]
echo 'ok    plain Codex first notify binds stable identity; stale and side-thread notifications stay inert'
# Launcher records are durable accounting, not resumable subagents.
record_set a000000000001 name launcher-record
record_set a000000000001 id launcher-session
record_set a000000000001 kind claude
record_set a000000000001 dir "$tmp"
record_set a000000000001 launcher 1
record_set a000000000001 closed "$(date +%s)"
record_set a000000000002 name helper-record
record_set a000000000002 id helper-session
record_set a000000000002 kind claude
record_set a000000000002 dir "$tmp"
record_set a000000000002 parent a000000000001
record_set a000000000002 closed "$(date +%s)"
rows >"$tmp/rows"
if grep -q '^closed:a000000000001 ' "$tmp/rows"; then exit 1; fi
grep -q 'helper-record' "$tmp/rows"
[ -f "$(sessions_dir)/a000000000001" ]
echo 'ok    launcher record retained but omitted from reopenable rows'
echo 'PASS: tracking'
