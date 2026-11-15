#!/usr/bin/env bash
# Native conversation clearing: descendant guards, empty prompts and session rebinding.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-clear-context-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-clear-context.XXXXXX")"
mkdir -p "$tmp/bin"
for kind in claude codex other; do
  cat > "$tmp/bin/$kind" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
glyph='❯'; [ "${0##*/}" != codex ] || glyph='›'
printf '%s ' "$glyph"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$TEST_LOG/$TMUX_PANE.input"
  hint=""
  case "$line" in
    show-placeholder) hint='Try an example' ;;
    show-ghost) hint=/clear ;;
    show-codex-ghost) hint='Ask Codex to do anything' ;;
  esac
  if [ "$line" = show-codex-ghost ]; then
    printf '\033[1m›\033[0m \033[48;2;72;76;92m \033[2mAsk Codex to do anything\033[0m \033[48;2;72;76;92m\r\033[2C'
  elif [ -n "$hint" ]; then
    printf '%s\302\240\033[2m%s\033[0m\033[%sD' "$glyph" "$hint" "${#hint}"
  else printf '%s ' "$glyph"; fi
done
STUB
  chmod +x "$tmp/bin/$kind"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
export TMUX_ASK_IDLE_SECS=0 TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 100 -y 30 cat
tmux -L "$sock" has-session || exit 1
socket="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket' >&2; exit 1 ;; esac
export TMUX="$socket,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent owner
. "$B/lib.sh"
ensure_agent_ids
owner_id="$(pane_agent_id %0)"
wait_input() {
  local i
  for ((i=0; i<100; i++)); do
    if [ -f "$tmp/$1.input" ] && grep -Fxq -- "$2" "$tmp/$1.input"; then return 0; fi
    sleep .05
  done
  echo "FAIL missing input $2 in $1" >&2; return 1
}
new_agent() {
  local kind="$1" name="$2" i
  pane="$(tmux new-window -d -P -F '#{pane_id}' "env TEST_LOG='$tmp' '$TMUX_SPAWN_BIN/$kind'")"
  tmux set -p -t "$pane" @agent "$name"
  tmux set -p -t "$pane" @parent %0
  tmux set -p -t "$pane" @state idle
  identity="$(ensure_agent_id "$pane")"
  record_set "$identity" kind "$kind"
  for ((i=0; i<100; i++)); do
    if tmux capture-pane -p -t "$pane" | grep -q "FAKE $kind"; then break; fi
    sleep .05
  done
  tmux capture-pane -p -t "$pane" | grep -q "FAKE $kind"
}
refuse() {
  local reason="$1" name="$2" status=0
  "$B/tmux-clear-context" --from owner "$name" > "$tmp/out" 2>&1 || status=$?
  if [ "$status" != 1 ] || ! grep -Fq "$reason" "$tmp/out"; then cat "$tmp/out"; return 1; fi
  [ "$(wc -l < "$tmp/out" | tr -d ' ')" = 1 ]
  echo "PASS refusal: $reason"
}
new_agent claude child
claude_pane="$pane" claude_id="$identity"
new_agent codex coder
codex_pane="$pane" codex_id="$identity"
new_agent other external
refuse 'not a Claude or Codex' external
refuse 'not your descendant' owner
tmux set -pu -t "$claude_pane" @parent
refuse 'not your descendant' child
tmux set -p -t "$claude_pane" @parent %0
tmux set -p -t "$claude_pane" @state working
tmux set -p -t "$claude_pane" @activity 'testing unfinished work'
tmux set -p -t "$claude_pane" @state_since "$(( $(date +%s) - 2520 ))"
refuse 'child is working (since 42m): testing unfinished work' child
tmux set -p -t "$claude_pane" @state idle
tmux copy-mode -t "$claude_pane"
refuse 'in copy mode' child
tmux send-keys -t "$claude_pane" -X cancel
queue="$(message_queue_dir)"; mkdir -p "$queue"
for suffix in msg sending msg.sending; do
  file="$queue/1-1-${claude_pane#%}.$suffix"
  printf 'queued request\n' > "$file"
  refuse 'has queued messages' child
  rm "$file"
done
# A delivery holding the same kernel lock must exclude slash input.
# Expanded by the lock holder shell.
# shellcheck disable=SC2016
with_lock "$queue/.pane-${claude_pane#%}.lock" /bin/bash -c \
  'touch "$1/locked"; while [ ! -f "$1/release" ]; do sleep .05; done' lock "$tmp" &
lock_pid=$!
for ((i=0; i<100; i++)); do [ ! -f "$tmp/locked" ] || break; sleep .05;done
[ -f "$tmp/locked" ]
refuse 'message delivery in progress' child
touch "$tmp/release"; wait "$lock_pid"
# Simulate a recently active client without attaching to the user's server.
real_tmux="$(command -v tmux)"
mkdir -p "$tmp/client-bin"
cat > "$tmp/client-bin/tmux" <<'CLIENT'
#!/usr/bin/env bash
if [ "$1" = list-clients ]; then
  printf '%s %s\n' "$BUSY_PANE" "$(date +%s)"
else
  exec "$REAL_TMUX" "$@"
fi
CLIENT
chmod +x "$tmp/client-bin/tmux"
export REAL_TMUX="$real_tmux" BUSY_PANE="$claude_pane"
PATH="$tmp/client-bin:$PATH" TMUX_ASK_IDLE_SECS=8 refuse 'recent user input' child
# Neither ordinary drafts nor text matching the old placeholder are empty.
for draft_name in child coder; do
  draft_pane="$claude_pane"; [ "$draft_name" != coder ] || draft_pane="$codex_pane"
  for draft in 'hello unfinished draft' 'Try my unfinished draft'; do
    tmux send-keys -t "$draft_pane" -l "$draft"
    refuse 'did not reach an empty prompt' "$draft_name"
    [ ! -e "$tmp/$draft_pane.input" ]
    tmux send-keys -t "$draft_pane" C-u
  done
done
for key in owed_to owed_msg owed_at owed owed_settled owed_notified owed_asked; do
  tmux set -p -t "$claude_pane" "@$key" old
done
"$B/tmux-clear-context" --from owner child > "$tmp/out"
grep -Fxq 'cleared child (/clear)' "$tmp/out"
wait_input "$claude_pane" /clear
for key in activity owed_to owed_msg owed_at owed owed_settled owed_notified owed_asked; do
  [ -z "$(tmux show -pqv -t "$claude_pane" "@$key")" ]
done
[ "$(pane_agent_id "$claude_pane")" = "$claude_id" ]
[ "$(tmux show -pqv -t "$claude_pane" @parent)" = %0 ]
new_session=12345678-1234-4234-8234-123456789abc
printf '{"session_id":"%s","prompt":"back"}' "$new_session" |
  "$B/tmux-agent-report" --pane "$claude_pane" --turn-start
[ "$(record_get "$claude_id" id)" = "$new_session" ]
echo 'PASS Claude /clear preserves identity, clears owed/activity and records the new session'
record_set "$codex_id" id old-thread
tmux set -p -t "$codex_pane" @codex_thread old-thread
"$B/tmux-clear-context" --from owner coder > "$tmp/out"
grep -Fxq 'cleared coder (/new)' "$tmp/out"
wait_input "$codex_pane" /new
[ -z "$(tmux show -pqv -t "$codex_pane" @codex_thread)" ]
[ -z "$(record_get "$codex_id" id)" ]
"$B/tmux-agent-report" --agent-id "$codex_id" --codex-notify \
  '{"type":"agent-turn-complete","thread-id":"new-thread","input-messages":[],"last-assistant-message":"back"}'
[ "$(tmux show -pqv -t "$codex_pane" @codex_thread)" = new-thread ]
[ "$(record_get "$codex_id" id)" = new-thread ]
echo 'PASS Codex /new clears the old thread binding and the next notify rebinds it'
# A configured Codex profile has the same native command.
record_set "$codex_id" kind extra
"$B/tmux-clear-context" --from owner coder > "$tmp/out"
grep -Fxq 'cleared coder (/new)' "$tmp/out"
[ "$(pane_agent_id %0)" = "$owner_id" ]
echo 'PASS Codex profile supports clearing; caller identity remains unchanged'
# Ghost text is dim output with an NBSP separator and the cursor restored to
# the input start. Test C locale explicitly as well as the inherited locale.
for ghost_case in placeholder history codex; do
  kind=claude show='show-placeholder' command=/clear
  if [ "$ghost_case" = history ]; then show='show-ghost'; fi
  if [ "$ghost_case" = codex ]; then kind=codex; show='show-codex-ghost'; command=/new; fi
  new_agent "$kind" "$ghost_case"
  ghost_pane="$pane"
  tmux send-keys -t "$ghost_pane" "$show" Enter
  for ((i=0; i<100; i++)); do
    if tmux capture-pane -p -e -t "$ghost_pane" | grep -Fq $'\033[2m'; then break; fi
    sleep .05
  done
  tmux capture-pane -p -e -t "$ghost_pane" | grep -Fq $'\033[2m'
  [ "$(tmux display -p -t "$ghost_pane" '#{cursor_x}')" = 2 ]
  if [ "$ghost_case" = history ]; then
    LC_ALL=C "$B/tmux-clear-context" --from owner "$ghost_case" > "$tmp/out"
  else "$B/tmux-clear-context" --from owner "$ghost_case" > "$tmp/out"; fi
  grep -Fxq "cleared $ghost_case ($command)" "$tmp/out"
  wait_input "$ghost_pane" "$command"
  echo "PASS $ghost_case dim suggestion accepts the native command"
done
# Change readiness immediately after literal input, with explicit events
# instead of sleeps. Record every Backspace sent to the private test pane.
cat > "$tmp/client-bin/tmux" <<'AFTER'
#!/usr/bin/env bash
if [ "$1" = send-keys ]; then
  for arg in "$@"; do
    if [ "$arg" = BSpace ]; then printf 'BSpace\n' >> "$KEY_TRACE"; fi
  done
fi
"$REAL_TMUX" "$@" || exit $?
if [ "$1" = send-keys ] && [ "${4:-}" = -l ]; then
  case "${5:-}" in /clear|/new)
    case "$AFTER_TYPING" in
      working) "$REAL_TMUX" set -p -t "$3" @state working ;;
      queued) printf 'queued request\n' > "$POST_QUEUE_FILE" ;;
      replace) "$REAL_TMUX" set -p -t "$3" @agent_id a000000000099 ;;
      draft)
        "$REAL_TMUX" send-keys -t "$3" -l ' mine'
        "$REAL_TMUX" set -p -t "$3" @state working ;;
      copy) "$REAL_TMUX" copy-mode -t "$3" ;;
    esac ;;
  esac
fi
AFTER
export KEY_TRACE="$tmp/keys" POST_QUEUE_FILE="$queue/post-typing.msg" AFTER_TYPING=""
for kind in claude codex; do
  command=/clear; [ "$kind" != codex ] || command=/new
  for event in working queued; do
    name="$kind-$event"
    new_agent "$kind" "$name"
    post_pane="$pane"
    POST_QUEUE_FILE="$queue/2-2-${post_pane#%}.msg"
    : > "$KEY_TRACE"
    AFTER_TYPING="$event" PATH="$tmp/client-bin:$PATH" refuse "erased input: $command" "$name"
    [ "$(wc -l < "$KEY_TRACE" | tr -d ' ')" = "${#command}" ]
    [ ! -e "$tmp/$post_pane.input" ]
    # Enter logs the actual canonical input buffer, not merely the rendering.
    tmux send-keys -t "$post_pane" Enter
    wait_input "$post_pane" ''
    [ "$(cat "$tmp/$post_pane.input")" = '' ]
    rm -f "$POST_QUEUE_FILE"
    echo "PASS $kind $event refusal erases exactly the command before exiting"
  done
done
for event in replace draft copy; do
  name="unsafe-$event"
  new_agent claude "$name"
  post_pane="$pane" post_id="$identity"
  : > "$KEY_TRACE"
  AFTER_TYPING="$event" PATH="$tmp/client-bin:$PATH" refuse 'input left as is: /clear' "$name"
  [ ! -s "$KEY_TRACE" ]
  [ ! -e "$tmp/$post_pane.input" ]
  if [ "$event" = replace ]; then tmux set -p -t "$post_pane" @agent_id "$post_id"; fi
  if [ "$event" = copy ]; then tmux send-keys -t "$post_pane" -X cancel; fi
  tmux send-keys -t "$post_pane" Enter
  expected=/clear; [ "$event" != draft ] || expected='/clear mine'
  wait_input "$post_pane" "$expected"
  echo "PASS $event refusal sends no Backspace and preserves the input"
done
# Introduce a draft only on the second prompt capture, just before typing.
new_agent claude late-draft
late_pane="$pane"
export CAPTURE_COUNT="$tmp/capture-count"
cat > "$tmp/client-bin/tmux" <<'BEFORE'
#!/usr/bin/env bash
if [ "$1" = capture-pane ]; then
  count=0; [ ! -f "$CAPTURE_COUNT" ] || read -r count < "$CAPTURE_COUNT"
  count=$((count+1)); printf '%s\n' "$count" > "$CAPTURE_COUNT"
  if [ "$count" = 2 ]; then "$REAL_TMUX" send-keys -t "${5}" -l 'late draft'; fi
fi
exec "$REAL_TMUX" "$@"
BEFORE
PATH="$tmp/client-bin:$PATH" refuse 'no longer has an empty prompt' late-draft
[ ! -e "$tmp/$late_pane.input" ]
tmux send-keys -t "$late_pane" Enter
wait_input "$late_pane" 'late draft'
echo 'PASS prompt is rechecked immediately before literal input'
echo 'PASS clear-context'
