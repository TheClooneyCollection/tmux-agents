#!/usr/bin/env bash
# Rename authorization, names, persisted links, durable notices and queue races.
# All panes are stubs on an isolated server; run with </dev/null.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-rename-test-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-rename-test.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED TMUX_AGENTS_NAME_FORMAT
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0
Q="/tmp/tmux-agents-$(id -u)/queue/$sock"
legacy="${Q%/*}/rename-test-$$"
other="${Q%/*}/other-rename-test-$$"
. "$here/tests/helpers/cleanup.sh"
cleanup() {
  cleanup_test_server || return
  rm -rf "$state_dir" "$other"
  rm -f "$legacy.meta" "$legacy.undelivered"
}
trap cleanup EXIT
mkdir -p "$state_dir/stubs"
for kind in claude codex; do
  printf '#!/bin/sh\nprintf "STUB-%s\\n"\nexec cat\n' "$kind" > "$state_dir/stubs/$kind"
  chmod +x "$state_dir/stubs/$kind"
done
export TMUX_SPAWN_BIN="$state_dir/stubs"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 200 -y 50 cat
tmux -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0"
tmux set -g default-shell /bin/sh
tmux respawn-pane -k -t %0 "$state_dir/stubs/claude"
tmux new-window -d "$state_dir/stubs/codex"
tmux new-window -d "$state_dir/stubs/claude"
tmux new-window -d "$state_dir/stubs/codex"
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"
check() { "$@" || { echo "FAIL: $*"; exit 1; }; echo "ok: $*"; }
reject() { if "$@" > "$state_dir/rejected" 2>&1; then echo "unexpected success: $*"; return 1; fi; }
captured() { local content; content="$(tmux capture-pane -p -J -S -300 -t "$1")"; case "$content" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
wait_for() { local i; for ((i=0; i<100; i++)); do "$@" && return 0; sleep .05; done; return 1; }
check wait_for captured %0 STUB-claude
check wait_for captured %1 STUB-codex
set_name %0 parent; set_name %1 child; set_name %2 peer; set_name %3 stranger
tmux set -p -t %1 @parent %0
set_peers %0 '%1 %2'; set_peers %1 %0; set_peers %2 %0
check reject "$B/tmux-rename" --from peer parent nope --exact
check reject "$B/tmux-rename" --from stranger parent nope --exact
check reject "$B/tmux-rename" --from child parent nope --exact
check reject "$B/tmux-rename" --from missing parent nope --exact
check reject "$B/tmux-rename" parent 'bad name' --exact
check reject "$B/tmux-rename" parent peer --exact
check reject "$B/tmux-rename" absent valid --exact
check "$B/tmux-rename" --from parent child kid --exact
check test "$(pane_name %1)" = kid
tmux set -p -t %3 @parent %1
check "$B/tmux-rename" --from parent stranger grandchild --exact
check test "$(pane_name %3)" = grandchild
# Prefix matches suggest_name even when a stub has exec'd cat.
prefix="$(suggest_name %1)"; prefix="${prefix%-*}-"
check "$B/tmux-rename" --from kid kid short
check test "$(pane_name %1)" = "${prefix}short"
check "$B/tmux-rename" "${prefix}short" "Auth Review"
check test "$(pane_name %1)" = "${prefix}Auth-Review"
check reject "$B/tmux-rename" "${prefix}Auth-Review" "Auth Review" --exact
check "$B/tmux-rename" "${prefix}Auth-Review" "${prefix}full"
check test "$(pane_name %1)" = "${prefix}full"
tmux set -g @tmux_agents_name_format exact
check "$B/tmux-rename" "${prefix}full" option-exact
check test "$(pane_name %1)" = option-exact
check env TMUX_AGENTS_NAME_FORMAT= "$B/tmux-rename" option-exact empty-env
check test "$(pane_name %1)" = empty-env
check "$B/tmux-rename" empty-env option-exact
check env TMUX_AGENTS_NAME_FORMAT=prefixed "$B/tmux-rename" option-exact env-prefix
check test "$(pane_name %1)" = "${prefix}env-prefix"
tmux set -g @tmux_agents_name_format prefixed
check env TMUX_AGENTS_NAME_FORMAT=exact "$B/tmux-rename" "${prefix}env-prefix" env-exact
check test "$(pane_name %1)" = env-exact
check env TMUX_AGENTS_NAME_FORMAT=invalid "$B/tmux-rename" env-exact kid --exact
check reject env TMUX_AGENTS_NAME_FORMAT=invalid "$B/tmux-rename" kid no
check test "$(format_given_name codex "$HOME" main 0)" = 'codex-~-main'
check test "$(format_given_name codex "$HOME" codex-~-main 0)" = 'codex-~-main'
check test "$(format_given_name bash "$HOME" main 0)" = '~-main'
# Persisted and live references, whole-word lists, current/legacy/other queues.
parent_id="$(pane_agent_id %0)" kid_id="$(pane_agent_id %1)"
closed_id="$(new_agent_id)" reserved_id="$(new_agent_id)"
record_set "$parent_id" name parent
record_set "$parent_id" id parent-session
record_set "$kid_id" parent "$parent_id"
record_set "$closed_id" name closed-child
record_set "$closed_id" parent "$parent_id"
record_set "$reserved_id" name reserved
record_set "$reserved_id" id reserved-session
check "$B/tmux-rename" parent reserved --exact
check "$B/tmux-rename" reserved parent --exact
tmux set -p -t %2 @awaiting "$parent_id parent-tail"
tmux set -p -t %2 @closed "parent-tail $parent_id"
tmux set -p -t %0 @state "done"
tmux set -p -t %2 @state idle
tmux copy-mode -t %0
tmux copy-mode -t %2
mkdir -p "$Q" "$other"
printf 'from_name=parent\nto_name=parent\nkind=reply\n' > "$legacy.meta"
printf 'legacy-body\n' > "$legacy.undelivered"
cp "$legacy.meta" "$other/foreign.meta"
printf 'from_pane=%%0\nfrom_name=parent\nto_pane=%%1\nto_name=kid\nkind=reply\nqueued_at=1\n' > "$Q/1-retained-1.meta"
printf 'retained-body\n' > "$Q/1-retained-1.undelivered"
"$B/tmux-ask" --from kid parent queued-identity-body >/dev/null
body="$(find "$Q" -name '*.msg' | head -n 1)"
cp "$body" "$state_dir/body-before"
check "$B/tmux-rename" --from parent parent renamed --exact
check test "$(pane_name %0)" = renamed
check test ! -e "$(sessions_dir)/parent"
check test "$(record_get "$parent_id" id)" = parent-session
check test "$(record_get "$kid_id" parent)" = "$parent_id"
check test "$(record_get "$closed_id" parent)" = "$parent_id"
check test "$(tmux show -pqv -t %1 @parent)" = %0
check test "$(tmux show -pqv -t %2 @awaiting)" = "$parent_id parent-tail"
check test "$(tmux show -pqv -t %2 @closed)" = "parent-tail $parent_id"
check test "$(tmux show -pqv -t %2 @peer_names)" = renamed
check grep -qx "to_id=$parent_id" "${body%.msg}.meta"
check cmp "$body" "$state_dir/body-before"
check grep -qx from_name=parent "$legacy.meta"
check grep -qx to_name=parent "$legacy.meta"
check grep -qx from_name=parent "$other/foreign.meta"
check grep -qx from_name=parent "$Q/1-retained-1.meta"
check grep -qx retained-body "$Q/1-retained-1.undelivered"
check test "$(tmux show -pqv -t %2 @state)" = idle
check reject "$B/tmux-ask" --from kid parent old-name
# Both self and peer notices persist while busy, with correct metadata.
notice_matches() {
  local f
  for f in "$Q"/*.msg; do
    [ -f "$f" ] || continue
    if grep -qF "$2" "$f" && grep -qx 'from_name=tmux-rename' "${f%.msg}.meta" && grep -qx "to_name=$1" "${f%.msg}.meta"; then return 0; fi
  done
  return 1
}
check notice_matches renamed 'you are now renamed; pass --from renamed from now on'
check notice_matches peer 'parent is now renamed'
tmux send-keys -t %0 -X cancel
tmux send-keys -t %2 -X cancel
"$B/tmux-ask" --kick %0
"$B/tmux-ask" --kick %2
check wait_for captured %0 queued-identity-body
check wait_for captured %0 'notice from tmux-rename to renamed'
check wait_for captured %2 'parent is now renamed'
check "$B/tmux-ask" --from kid --reply renamed child-reply-after-rename
check test "$(tmux show -pqv -t %1 @state)" = "done"
check wait_for captured %0 child-reply-after-rename
# A delivery holds a shared identity lock through paste/Enter. Rename waits
# for it, then leaves neither resurrected metadata nor a lost message.
TMUX_ASK_ENTER_DELAY=1 "$B/tmux-ask" --from kid renamed concurrent-body > "$state_dir/send-result" &
sender=$!
sending_exists() { local f; for f in "$Q"/*.sending; do [ -f "$f" ] || continue; grep -q concurrent-body "$f" && return 0; done; return 1; }
check wait_for sending_exists
check "$B/tmux-rename" renamed final --exact
wait "$sender"
check wait_for captured %0 concurrent-body
no_orphan_meta() { local f stem; for f in "$Q"/*.meta; do [ -f "$f" ] || continue; stem="${f%.meta}"; [ -f "$stem.msg" ] || [ -f "$stem.sending" ] || [ -f "$stem.undelivered" ] || return 1; done; return 0; }
check no_orphan_meta
check test "$(pane_name %0)" = final
echo 'all rename tests passed'
