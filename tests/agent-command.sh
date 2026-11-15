#!/usr/bin/env bash
# Peers/connect use recorded kinds and real process ancestry, not launcher shells.
# Fake agent processes are symlinks to sleep, never real Claude/Codex binaries.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agent-command-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-command.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin space" "$tmp/home" "$tmp/alpha"
ln -s /bin/sleep "$tmp/bin space/claude"
ln -s /bin/sleep "$tmp/bin space/codex"
cat >"$tmp/fixture" <<'STUB'
#!/bin/sh
"$1/bin space/$2" 600 &
child=$!
printf '%s\n' "$child" >"$1/$2.pid"
printf 'COMMAND STUB READY\n'
wait "$child"
printf 'COMMAND STUB EXITED\n'
while IFS= read -r line; do :; done
STUB
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin space" TMUX_ASK_ENTER_DELAY=0
export TMUX_AGENTS_CODEX_HOMES="account=$tmp/home"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent caller
peer="$(tmux split-window -d -h -t %0 -P -F '#{pane_id}' "/bin/sh '$tmp/fixture' '$tmp' claude")"
tmux set -p -t "$peer" @agent helper
tmux set -p -t "$peer" @tracked 1
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
record_set "$(pane_agent_id "$peer")" kind claude
fail=0 count=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=$((fail+1)); fi; }
# Invoked through check.
# shellcheck disable=SC2329
wait_text() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    tmux capture-pane -p -t "$1" >"$tmp/screen"
    grep -Fq "$2" "$tmp/screen" && return 0
    sleep .05
  done
  return 1
}
check 'fake Claude child ready' wait_text "$peer" 'COMMAND STUB READY'
raw="$(pane_command "$peer")"
check 'fixture foreground is not the agent' test "$raw" != claude
"$B/tmux-connect" --from caller claude >"$tmp/connect"
check 'type shortcut finds started Claude despite arbitrary label' grep -Fq 'helper' "$tmp/connect"
"$B/tmux-peers" --from caller >"$tmp/peers"
check 'peers command identifies live Claude child' grep -Eq 'helper[[:space:]]+%[0-9]+[[:space:]]+claude[[:space:]]' "$tmp/peers"
"$B/tmux-connect" --from caller --list >"$tmp/list"
check 'connect list identifies Claude' grep -Eq 'helper[[:space:]]+claude[[:space:]]' "$tmp/list"
check 'untracked pane retains raw command' test "$(pane_agent_command %0)" = "$(pane_command %0)"
tmux set -p -t "$peer" @shell 1
check 'marked shell retains raw command' test "$(pane_agent_command "$peer")" = "$raw"
tmux set -pu -t "$peer" @shell
if ! kill -0 "$(cat "$tmp/claude.pid")" 2>/dev/null; then
  tmux capture-pane -p -S -100 -t "$peer"
  echo "FAIL fake child ended before explicit stop"
  exit 1
fi
kill "$(cat "$tmp/claude.pid")"
check 'fake child exited while shell stays' wait_text "$peer" 'COMMAND STUB EXITED'
"$B/tmux-peers" --from caller >"$tmp/peers"
check 'peers marks exited recorded Claude' grep -Fq 'claude (exited)' "$tmp/peers"
"$B/tmux-connect" --from caller --list >"$tmp/list"
check 'connect list marks exited recorded Claude' grep -Fq 'claude (exited)' "$tmp/list"
profile="$(tmux new-window -d -P -F '#{pane_id}' -n profile-window -c "$tmp/alpha" "/bin/sh '$tmp/fixture' '$tmp' codex")"
tmux set -p -t "$profile" @agent custom-label
tmux set -p -t "$profile" @tracked 1
ensure_agent_id "$profile" >/dev/null
record_set "$(pane_agent_id "$profile")" kind account
check 'fake Codex profile ready' wait_text "$profile" 'COMMAND STUB READY'
check 'profile label uses recorded kind' test "$(pane_agent_command "$profile")" = account
"$B/tmux-connect" --from caller codex@alpha >"$tmp/connect"
check 'project type shortcut recognizes arbitrary Codex profile' grep -Fq 'custom-label' "$tmp/connect"
window="$(tmux display-message -p -t "$profile" '#{window_index}')"
"$B/tmux-connect" --from caller "codex@work:$window" >"$tmp/connect"
check 'window type shortcut recognizes recorded profile' grep -Fq 'custom-label' "$tmp/connect"
"$B/tmux-connect" --from caller --list >"$tmp/list"
check 'profile command remains its recorded name' grep -Eq 'custom-label[[:space:]]+account[[:space:]]' "$tmp/list"
other="$(tmux new-window -d -P -F '#{pane_id}' "/bin/sh '$tmp/fixture' '$tmp' claude")"
check 'unrelated fake Claude ready' wait_text "$other" 'COMMAND STUB READY'
check 'unrelated live Claude does not revive exited Claude' test "$(pane_agent_command "$peer")" = 'claude (exited)'
printf '%s checks, %s failures\n' "$count" "$fail"
[ "$fail" = 0 ]
