#!/usr/bin/env bash
# Regression tests for how names and tmux targets resolve: a name that no
# longer exists must fail, never land on some other pane through tmux's
# loose target matching. Also covers tmux-connect --as rename integration.
# Runs on an isolated tmux server.
#
#   tests/names.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-test-$$"
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"

unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state_dir" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
mkdir -p "$state_dir/bin"
cat >"$state_dir/bin/claude" <<'STUB'
#!/bin/sh
printf 'NAMES STUB READY\n'
exec cat
STUB
cp "$state_dir/bin/claude" "$state_dir/bin/codex"
chmod +x "$state_dir/bin/claude" "$state_dir/bin/codex"
export TMUX_SPAWN_BIN="$state_dir/bin"

tmux -L "$sock" -f /dev/null new-session -d -s work -x 120 -y 30 "exec /bin/sh '$state_dir/bin/claude'"
# Never let this reach the user's live server: the test server must be up,
# on a real socket that isn't the default one.
tmux -L "$sock" has-session 2>/dev/null || { echo "ABORT: test server not up"; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$state_dir"; }
trap cleanup EXIT
tmux set-option -g default-shell /bin/sh

# me (%0) in window 0. Window 1 is called blog.example.io and holds
# claude-blog.example.io-1 (%1), connected to me. The agent that used to
# be called blog.example.io-1 is gone.
tmux new-window -d -t work:1 -n blog.example.io "exec /bin/sh '$state_dir/bin/codex'"
tmux set -p -t %0 @agent me; tmux set -p -t %1 @agent claude-blog.example.io-1
. "$B/lib.sh"
ensure_agent_ids "$state_dir/empty-queue"
TMUX_PANE=%0 "$B/tmux-connect" --from me claude-blog.example.io-1 >/dev/null

fail=0
check() {  # name, then the command; passes if the command's success matches $2
  local name="$1" want="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fails; fi
  if [ "$got" = "$want" ]; then echo "ok    $name ($got)"; else echo "FAIL  $name: $got, wanted $want"; fail=1; fi
}
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
wait_for() {
  local i=0
  while [ "$i" -lt 100 ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
ready() { tmux capture-pane -p -t "$1" | grep -q 'NAMES STUB READY'; }
check "first stub is ready" ok wait_for ready %0
check "second stub is ready" ok wait_for ready %1
[ "$fail" -eq 0 ] || exit 1
hits() { tmux capture-pane -p -J -t %1 -S -200 | grep -c "$1"; }

check "a closed agent's name fails"            fails env TMUX_PANE=%0 "$B/tmux-ask" blog.example.io-1 "stale-name-test"
check "...with --any too"                      fails env TMUX_PANE=%0 "$B/tmux-ask" --any blog.example.io-1 "stale-any-test"
check "...for tmux-peek"                       fails env TMUX_PANE=%0 "$B/tmux-peek" blog.example.io-1
check "...for tmux-connect (agent mode)"       fails env TMUX_PANE=%0 "$B/tmux-connect" --from me blog.example.io-1
n="$(( $(hits stale-name-test) + $(hits stale-any-test) ))"
if [ "$n" -eq 0 ]; then echo "ok    nothing reached the pane in the same-named window"
else echo "FAIL  a message for the closed agent reached %1"; fail=1; fi

check "a name with dots still works"           ok    env TMUX_PANE=%0 "$B/tmux-ask" claude-blog.example.io-1 "dots-test"
check "a pane id works"                        ok    env TMUX_PANE=%0 "$B/tmux-ask" --any %1 "id-test"
check "session:window.pane works"              ok    env TMUX_PANE=%0 "$B/tmux-peek" work:1.0
check "a window number works (connect)"        ok    env TMUX_PANE=%0 "$B/tmux-connect" 1 --as me

# Keep messages parked while exercising both directions of queued metadata.
# Pane and agent IDs stay stable while display labels change.
mkdir -p "$state_dir/prefixed-project"
observer="$(tmux split-window -d -h -t %0 -c "$state_dir/prefixed-project" -P -F '#{pane_id}' "exec /bin/sh '$state_dir/bin/codex'")"
tmux set -p -t "$observer" @agent codex-prefixed-project-review
check "prefixed stub is ready" ok wait_for ready "$observer"
. "$B/lib.sh"
me_id="$(ensure_agent_id %0)"
peer_id="$(ensure_agent_id %1)"
child_id="$(new_agent_id)"
closed_id="$(new_agent_id)"
tmux set -p -t "$observer" @closed "before $me_id after"
tmux copy-mode -t %0
tmux copy-mode -t %1
records="$state_dir/tmux-agents/$sock/sessions"
mkdir -p "$records" "$queue"
record_set "$me_id" name me
record_set "$me_id" kind claude
record_set "$me_id" id connect-session
record_set "$child_id" parent "$me_id"
record_set "$closed_id" parent "$me_id"
record_set "$closed_id" closed 123
tmux set -p -t %1 @parent %0
tmux set -p -t %1 @awaiting "before $me_id after"
tmux set -p -t %1 @closed "before $me_id after"
printf 'connect-queued-fixture\n' >"$queue/connect-fixture.msg"
printf 'from_pane=%%1\nfrom_name=claude-blog.example.io-1\nto_pane=%%0\nto_name=me\nkind=request\nqueued_at=1\n' >"$queue/connect-fixture.meta"
printf 'from_id=%s\nto_id=%s\n' "$peer_id" "$me_id" >>"$queue/connect-fixture.meta"
printf 'connect-undelivered-fixture\n' >"$queue/connect-saved.undelivered"
printf 'from_pane=%%0\nfrom_name=me\nto_pane=%%1\nto_name=claude-blog.example.io-1\nkind=reply\nqueued_at=2\n' >"$queue/connect-saved.meta"
printf 'from_id=%s\nto_id=%s\n' "$me_id" "$peer_id" >>"$queue/connect-saved.meta"
check "--as migrates an existing exact name" ok env TMUX_PANE=%0 "$B/tmux-connect" --from me --as renamed claude-blog.example.io-1
check "--as retains exact name semantics" ok test "$(tmux show -pqv -t %0 @agent)" = renamed
check "old session record is removed" ok test ! -e "$records/me"
check "renamed record keeps session id" ok grep -qx 'id=connect-session' "$records/$me_id"
check "live child's saved parent retains identity" ok grep -qx "parent=$me_id" "$records/$child_id"
check "closed child's saved parent retains identity" ok grep -qx "parent=$me_id" "$records/$closed_id"
check "awaiting references retain identity" ok test "$(tmux show -pqv -t %1 @awaiting)" = "before $me_id after"
check "other panes' closed references retain identity" ok test "$(tmux show -pqv -t "$observer" @closed)" = "before $me_id after"
check "reconnected live peer is removed from closed references" ok test "$(tmux show -pqv -t %1 @closed)" = 'before after'
check "queued destination retains identity" ok grep -qx "to_id=$me_id" "$queue/connect-fixture.meta"
check "undelivered sender retains identity" ok grep -qx "from_id=$me_id" "$queue/connect-saved.meta"
check "queued message body is retained" ok grep -qx connect-queued-fixture "$queue/connect-fixture.msg"
check "undelivered body is retained" ok grep -qx connect-undelivered-fixture "$queue/connect-saved.undelivered"
check "self peer link survives" ok test "$(tmux show -pqv -t %0 @peers)" = %1
check "other peer link survives" ok test "$(tmux show -pqv -t %1 @peers)" = %0
check "live parent link survives" ok test "$(tmux show -pqv -t %1 @parent)" = %0
check "peer border label follows rename" ok test "$(tmux show -pqv -t %1 @peer_names)" = renamed
check "own peer border label survives" ok test "$(tmux show -pqv -t %0 @peer_names)" = claude-blog.example.io-1
check "old name cannot be peeked" fails env TMUX_PANE=%1 "$B/tmux-peek" --from claude-blog.example.io-1 me
check "old --from cannot rename again" fails env TMUX_PANE=%0 "$B/tmux-connect" --from me --as forbidden claude-blog.example.io-1
check "failed identity leaves name intact" ok test "$(tmux show -pqv -t %0 @agent)" = renamed
check "old name cannot receive messages" fails env TMUX_PANE=%1 "$B/tmux-ask" --from claude-blog.example.io-1 me stale-rename-message
check "old name cannot connect" fails env TMUX_PANE=%1 "$B/tmux-connect" --from claude-blog.example.io-1 me
# The renamed sender must clear the new awaiting token when replying.
tmux send-keys -t %1 -X cancel
check "new name can reply" ok env TMUX_PANE=%0 "$B/tmux-ask" --from renamed --reply claude-blog.example.io-1 connect-rename-reply
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
reply_received() { tmux capture-pane -p -J -t %1 -S -200 | grep -q 'connect-rename-reply'; }
check "reply reaches the connected peer" ok wait_for reply_received
check "reply clears renamed awaiting token" ok test "$(tmux show -pqv -t %1 @awaiting)" = 'before after'

# The stub process is cat, so kind matching must use the prefixed name.
check "codex finds a prefixed name in this window" ok env TMUX_PANE=%0 "$B/tmux-connect" --from renamed codex
check "codex@project finds a prefixed name" ok env TMUX_PANE=%0 "$B/tmux-connect" --from renamed codex@prefixed-project
check "prefixed target links back to the caller" ok test "$(tmux show -pqv -t "$observer" @peers)" = %0

# Picker callbacks read live tmux settings; the existing env override wins.
unset TMUX_CONNECT_HIGHLIGHT
tmux set -gu @tmux_agents_connect_highlight
check "highlight callback accepts default" ok env TMUX_CONNECT_PANES="%0 %1" "$B/tmux-connect" --highlight %1
check "highlight uses default style" ok test "$(tmux show -pqv -t %1 window-style)" = bg=colour24
tmux set -g @tmux_agents_connect_highlight bg=colour31
check "highlight callback accepts tmux option" ok env TMUX_CONNECT_PANES="%0 %1" "$B/tmux-connect" --highlight %1
check "highlight uses tmux option style" ok test "$(tmux show -pqv -t %1 window-style)" = bg=colour31
check "highlight callback accepts env override" ok env TMUX_CONNECT_PANES="%0 %1" TMUX_CONNECT_HIGHLIGHT=bg=colour42 "$B/tmux-connect" --highlight %0
check "highlight env overrides tmux option" ok test "$(tmux show -pqv -t %0 window-style)" = bg=colour42
check "highlight clears previous pane style" ok test -z "$(tmux show -pqv -t %1 window-style)"

[ "$fail" -eq 0 ] && echo "all passed" || echo "some failed"
exit "$fail"
