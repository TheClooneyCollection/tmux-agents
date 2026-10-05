#!/usr/bin/env bash
# Real fzf preview follow keeps a seven-line fixed header over long captures.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-preview-header-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-preview-header.XXXXXX")"
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
tmux -L "$sock" -f /dev/null new-session -d -x 140 -y 32 -s window-secret -c "$tmp" cat
tmux -L "$sock" has-session
socket="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket' >&2; exit 1;; esac
export TMUX="$socket,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
B="$here/bin"
cat >"$tmp/long" <<'SH'
#!/bin/sh
i=1
while [ "$i" -le 350 ]; do printf 'BODY-ROW-%03d\n' "$i"; i=$((i+1)); done
exec cat
SH
chmod +x "$tmp/long"
long="$(tmux new-window -d -P -F '#{pane_id}' "$tmp/long")"
short="$(tmux new-window -d -P -F '#{pane_id}' "printf 'SHORT-TAIL\n'; exec cat")"
tmux set -p -t "$long" @agent preview-long-agent
tmux set -p -t "$long" @activity '长活动 needs to stay visible while the pane output follows its last line'
tmux set -p -t "$short" @agent preview-short-agent
# Keep this capture shorter than the preview body (avoid trailing blank rows).
tmux resize-window -t "$(tmux display -p -t "$short" '#{window_id}')" -y 8
mkdir "$tmp/shim"
cat >"$tmp/shim/fzf" <<'SH'
#!/bin/sh
printf '%s\0' "$@" >"$PREVIEW_ARGS"
exit 1
SH
chmod +x "$tmp/shim/fzf"
PREVIEW_ARGS="$tmp/args" PATH="$tmp/shim:$PATH" "$B/tmux-agents" </dev/null
python3 - "$tmp" "$real_fzf" "$long" "$short" <<'PYTEST'
import pathlib,shlex,sys
root,fzf,long,short=sys.argv[1:]; root=pathlib.Path(root)
args=root.joinpath('args').read_bytes().decode().rstrip('\0').split('\0')
preview=args[args.index('--preview')+1]
window=next(a for a in args if a.startswith('--preview-window='))
assert window=='--preview-window=right,55%,follow,~7',window
root.joinpath('rows').write_text(long+'\n'+short+'\n')
root.joinpath('picker').write_text('#!/bin/sh\nexec '+shlex.join([fzf,'--layout=reverse','--preview',preview,window])+' <'+shlex.quote(str(root/'rows'))+'\n')
PYTEST
chmod +x "$tmp/picker"
ui="$(tmux new-window -d -P -F '#{pane_id}' "$tmp/picker")"
wait_view() {
  local name="$1" body="$2" i
  for ((i=0;i<100;i++)); do
    tmux capture-pane -p -t "$ui" >"$tmp/screen"
    if grep -q "$name" "$tmp/screen" && grep -q "$body" "$tmp/screen" && grep -q 'started' "$tmp/screen" && grep -q '─' "$tmp/screen"; then return 0; fi
    sleep .05
  done
  cat "$tmp/screen" >&2
  return 1
}
wait_view preview-long-agent BODY-ROW-350
echo 'ok real fzf follow keeps name, timing and separator above the final captured line'
tmux send-keys -t "$ui" Down
wait_view preview-short-agent SHORT-TAIL
echo 'ok switching to an activity-free preview keeps the fixed header'
tmux send-keys -t "$ui" C-c
