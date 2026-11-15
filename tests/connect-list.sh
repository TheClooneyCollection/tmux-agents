#!/usr/bin/env bash
# Connect list and picker group linked windows by stable window identity.
# Uses stub agents on an isolated tmux socket, including grouped sessions.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-connect-list-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-connect-list.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
mkdir -p "$tmp/bin"
cat > "$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'CONNECT LIST STUB READY\n'
exec cat
STUB
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
export TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d -s s1 -n elsewhere -x 120 -y 30 "exec /bin/sh '$tmp/bin/claude'"
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
caller="$(tmux new-window -d -t s1:1 -n caller-window -P -F '#{pane_id}' "exec /bin/sh '$tmp/bin/claude'")"
peer="$(tmux split-window -d -h -t "$caller" -P -F '#{pane_id}' "exec /bin/sh '$tmp/bin/codex'")"
# Invoked indirectly by wait_ready.
# shellcheck disable=SC2329
wait_ready() {
  local i
  for ((i=0;i<100;i++)); do
    if tmux capture-pane -p -t "$1" | grep -q 'CONNECT LIST STUB READY'; then return 0; fi
    sleep .05
  done
  return 1
}
for pane in %0 "$caller" "$peer"; do wait_ready "$pane" || { echo "FAIL stub not ready: $pane"; exit 1; }; done
tmux set -p -t %0 @agent elsewhere
tmux set -p -t "$caller" @agent caller
tmux set -p -t "$peer" @agent same-window
# A marked shell must stay out even when CONNECT_FMT gains a field.
shell="$(tmux split-window -d -v -t %0 -P -F '#{pane_id}' 'exec cat')"
tmux set -p -t "$shell" @agent excluded-shell
tmux set -p -t "$shell" @shell 1
tmux new-session -d -t s1 -s s2
tmux select-window -t s2:1
export TMUX_PANE="$caller"
"$B/tmux-connect" --from caller --list > "$tmp/list"
"$B/tmux-connect" --rows all "$caller" > "$tmp/rows"
python3 - "$tmp/list" "$tmp/rows" "$peer" <<'PY'
import re, sys
listing = open(sys.argv[1]).read()
rows = open(sys.argv[2]).read().split('\0')
headers = [line for line in listing.splitlines() if line.startswith('== ')]
assert len(headers) == 2, listing
assert 'caller-window  (this window)' in headers[0], listing
assert '(this window)' not in headers[1], listing
assert listing.count('same-window') == 1, listing
assert 'excluded-shell' not in listing, listing
assert re.match(r'\s*' + re.escape(sys.argv[3]) + r'\s', listing.splitlines()[1]), listing
assert rows[1].startswith(sys.argv[3] + ' '), rows
assert 'caller-window' in rows[1] and 'same-window' in rows[1], rows
assert 'excluded-shell' not in ''.join(rows), rows
print('PASS: grouped-session list marker, ordering, deduplication and shell filtering; picker ordering')
PY
