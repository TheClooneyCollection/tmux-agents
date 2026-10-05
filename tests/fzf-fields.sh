#!/usr/bin/env bash
# Real fzf matching uses only name/project, with horizontal scrolling disabled.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-fzf-fields-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-fzf-fields.XXXXXX")"
unset TMUX TMUX_PANE
export XDG_STATE_HOME="$tmp/state"
# shellcheck source=tests/helpers/cleanup.sh
. "$here/tests/helpers/cleanup.sh"
# Called by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
command -v fzf >/dev/null || { echo 'SKIP: fzf unavailable'; exit 0; }
real_fzf="$(command -v fzf)"
tmux -L "$sock" -f /dev/null new-session -d -s window-secret -c "$tmp" cat
tmux -L "$sock" has-session
socket="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket' >&2; exit 1;; esac
export TMUX="$socket,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent stoneage
pane="$(tmux new-session -d -s agents-garden -c "$tmp" -P -F '#{pane_id}' cat)"
tmux set -p -t "$pane" @agent codex-garden-worker
tmux set -p -t "$pane" @parent %0
tmux set -p -t "$pane" @state needs_you
tmux set -p -t "$pane" @activity activity-secret
# shellcheck source=bin/lib.sh
. "$here/bin/lib.sh"
ensure_agent_ids "$tmp/queue"
# Capture exactly the production picker arguments without starting a live UI.
mkdir "$tmp/shim"
cat > "$tmp/shim/fzf" <<'SHIM'
#!/bin/bash
printf '%s\0' "$@" > "$FZF_ARGS"
exit 1
SHIM
chmod +x "$tmp/shim/fzf"
FZF_ARGS="$tmp/args" PATH="$tmp/shim:$PATH" "$here/bin/tmux-agents" </dev/null
TMUX_AGENTS_LIST_FIELDS=1 FZF_PROMPT='agents · all windows> ' "$here/bin/tmux-agents" --list > "$tmp/rows"
python3 - "$real_fzf" "$tmp/args" "$tmp/rows" "$pane" <<'PY'
import pathlib, subprocess, sys
fzf, argfile, rowsfile, pane = sys.argv[1:]
args = pathlib.Path(argfile).read_bytes().decode().rstrip('\0').split('\0')
assert '--no-hscroll' in args, args
flags = [a for a in args if a in ('--read0', '--ansi', '--no-sort', '--no-hscroll') or a.startswith(('--delimiter=', '--with-nth=', '--nth='))]
rows = pathlib.Path(rowsfile).read_bytes().split(b'\0')[1:]
data = b'\0'.join(rows)
def matches(query):
    p = subprocess.run([fzf, *flags, '--filter=' + query], input=data, capture_output=True)
    assert p.returncode in (0, 1), p.stderr
    return p.stdout.decode()
for query in ('codex-garden-worker', 'garden'):
    assert 'codex-garden-worker' in matches(query), (query, matches(query))
for query in ('stoneage', 'needs', 'activity-secret', 'window-secret', 'you'):
    assert not matches(query), (query, matches(query))
print('8 fzf argument/name/project/excluded-field checks passed')
PY
