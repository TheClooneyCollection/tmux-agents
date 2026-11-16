#!/usr/bin/env bash
# Statusline unread count follows arrivals, cursor advances and retention using
# one pane lookup, without loading libraries or parsing JSON on the fast path.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; B="$here/bin"
sock="notes-count-$$"; tmp="$(mktemp -d "${TMPDIR:-/tmp}/notes-count.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_NOTES_DIGEST_SECS=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/fast-bin"
cat > "$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'STUB READY\n'
exec cat
STUB
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
export TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d cat
tmux -L "$sock" has-session || fail 'no test server'
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) fail 'unsafe socket' ;; esac
export TMUX="$S,1,0" TMUX_PANE=%1
tmux set-option -g default-shell /bin/sh
tmux new-window -d "$tmp/bin/codex"
tmux set -p -t %1 @agent receiver
ready=0
for ((attempt=0; attempt<100; attempt++)); do
  if tmux capture-pane -p -t %1 | grep -q 'STUB READY'; then ready=1; break; fi
  sleep .02
done
[ "$ready" = 1 ] || fail 'stub not ready'
. "$B/lib.sh"
. "$B/notes-lib.sh"
ensure_agent_ids "$tmp/empty"
receiver="$(pane_agent_id %1)"
NOTES_REAL_TMUX="$(command -v tmux)"
export NOTES_REAL_TMUX NOTES_COUNT_CALLS="$tmp/calls"
cat > "$tmp/fast-bin/tmux" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NOTES_COUNT_CALLS"
exec "$NOTES_REAL_TMUX" "$@"
STUB
cat > "$tmp/fast-bin/perl" <<'STUB'
#!/bin/bash
printf 'unexpected external command\n' >&2
exit 99
STUB
cp "$tmp/fast-bin/perl" "$tmp/fast-bin/dirname"
chmod +x "$tmp/fast-bin/"*
fast() {
  local expected="$1" calls="$2"
  shift 2
  : > "$tmp/calls"
  env "$@" PATH="$tmp/fast-bin:$PATH" /bin/bash "$B/tmux-notes" --count >"$tmp/count" 2>"$tmp/error" || fail "fast count exit: $(cat "$tmp/error")"
  printf '%s\n' "$expected" >"$tmp/expected"
  cmp -s "$tmp/expected" "$tmp/count" || fail "fast count expected $expected, got $(cat "$tmp/count")"
  [ ! -s "$tmp/error" ] || fail "fast count stderr: $(cat "$tmp/error")"
  if [ "$calls" = 0 ]; then
    [ ! -s "$tmp/calls" ] || fail 'unnecessary pane lookup'
  else
    printf 'display-message -p -t %s #{@agent_id}\n' "$TMUX_PANE" >"$tmp/expected-call"
    cmp -s "$tmp/expected-call" "$tmp/calls" || fail 'expected exactly one pane identity lookup'
  fi
}
parity() {
  local expected="$1" actual
  fast "$expected" 1
  actual="$("$B/tmux-notes" --from receiver --count)"
  [ "$actual" = "$expected" ] || fail "slow count expected $expected, got $actual"
}
# Empty statuslines succeed silently without creating storage or guessing panes.
fast 0 0 TMUX_PANE=
fast 0 0 TMUX=
fast 0 0 -u TMUX_PANE
fast 0 0 -u TMUX
(TMUX_PANE=%999; export TMUX_PANE; fast 0 1)
fast 0 1 TMUX="$tmp/missing-socket,1,0"
fast 0 1
[ ! -d "$(notes_dir)/$receiver" ] || fail 'fast count created storage'
tmux set -pu -t %1 @agent_id
fast 0 1
tmux set -p -t %1 @agent_id invalid
fast 0 1
tmux set -p -t %1 @agent_id "$receiver"
# Files published by the writer count immediately; reads consume the snapshot.
notes_write "$receiver" "$receiver" sender m01 first
parity 1
"$B/tmux-notes" --from receiver --keep-unread >"$tmp/read"
parity 1
"$B/tmux-notes" --from receiver >"$tmp/read"
parity 0
for ((i=2; i<=12; i++)); do
  notes_write "$receiver" "$receiver" sender "m$i" "arrival $i"
done
parity 11
notes_mark_read "$receiver" 9
parity 3
notes_mark_read "$receiver" 10
parity 2
# Reservation gaps and incomplete atomic writes never inflate the count.
note_dir="$(notes_dir)/$receiver"
printf 20 >"$note_dir/.sequence"
printf '{}' >"$note_dir/00000000000000000021-mff.json.123"
printf '{}' >"$note_dir/invalid.json"
printf '{}' >"$note_dir/00000000000000000022-no-token.json"
mkdir "$note_dir/00000000000000000023-mff.json"
fast 2 1
rm -r "$note_dir/00000000000000000023-mff.json"
notes_write "$receiver" "$receiver" sender m20 'after sequence gap'
parity 3
"$B/tmux-notes" --from receiver --all --count >"$tmp/count"
[ "$(cat "$tmp/count")" = 3 ] || fail 'count with other options changed semantics'
"$B/tmux-notes" --from receiver >"$tmp/read"
parity 0
# Expiry stays in the slow paths; once pruned, both counts agree.
now="$(date +%s)"
notes_write "$receiver" "$receiver" sender m30 expired "$((now - 604801))"
notes_snapshot "$receiver" >"$tmp/snapshot"
parity 0
notes_write "$receiver" "$receiver" sender m31 fresh
parity 1
# HOME fallback resolves the same server namespace without XDG_STATE_HOME.
mkdir -p "$tmp/home/.local"
ln -s "$XDG_STATE_HOME" "$tmp/home/.local/state"
fast 1 1 XDG_STATE_HOME= HOME="$tmp/home"
# Record one real invocation latency; do not impose a machine-dependent limit.
python3 - "$B/tmux-notes" <<'PY'
import subprocess
import sys
import time
start = time.perf_counter()
result = subprocess.run(['/bin/bash', sys.argv[1], '--count'], capture_output=True, check=True)
elapsed = (time.perf_counter() - start) * 1000
assert result.stdout == b'1\n' and result.stderr == b''
print(f'Bare count latency (one invocation): {elapsed:.3f} ms')
PY
echo 'PASS: statusline count, cursor parity, retention, silent fallback and builtin fast path'
