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
while IFS= read -r line; do
  i=$((i+1)); printf 'LIVE-TICK-%03d\n' "$i"
done
SH
chmod +x "$tmp/long"
long="$(tmux new-window -d -P -F '#{pane_id}' "$tmp/long")"
short="$(tmux new-window -d -P -F '#{pane_id}' "printf 'SHORT-TAIL\n'; exec cat")"
tmux set -p -t "$long" @agent preview-long-agent
tmux set -p -t "$long" @state working
tmux set -p -t "$long" @worked 0
tmux set -p -t "$long" @turn_start "$(date +%s)"
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
binds=[]
for i,arg in enumerate(args[:-1]):
    if arg!='--bind': continue
    value=args[i+1]
    if value.startswith('start:'):
        # Same production refresh-loop startup; static rows need no reload.
        value='start:execute-silent'+value.split('+execute-silent',1)[1]
    elif not value.startswith(('focus:','shift-up:','page-up:','alt-up:','preview-scroll-up:','shift-scroll-up:','ctrl-f:')):
        continue
    if 'change-preview-window' in value:
        for spec in value.split('change-preview-window(')[1:]: assert '~7' in spec.split(')',1)[0],value
    binds.extend(['--bind',value])
root.joinpath('picker').write_text('#!/bin/sh\nexec '+shlex.join([fzf,'--listen','--with-shell','bash -c','--layout=reverse','--preview',preview,window,*binds])+' <'+shlex.quote(str(root/'rows'))+'\n')
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
# Scroll away from the tail, then change both content and the ticking header.
# Wait for a changed timing row rather than sleeping for the preview timer.
wait_tick() {
  local previous="$1" i current
  for ((i=0;i<100;i++)); do
    tmux capture-pane -p -t "$ui" >"$tmp/screen"
    current="$(grep 'worked ' "$tmp/screen")"
    [ "$current" = "$previous" ] || return 0
    sleep .05
  done
  return 1
}
paused_view() {
  grep -q BODY-ROW "$tmp/screen" && ! grep -q LIVE-TICK "$tmp/screen" && grep -q preview-long-agent "$tmp/screen"
}
tmux send-keys -t "$ui" PPage PPage PPage
for n in 1 2; do
  tmux capture-pane -p -t "$ui" >"$tmp/screen"
  before="$(grep 'worked ' "$tmp/screen")"
  tmux send-keys -t "$long" "tick-$n" Enter
  wait_tick "$before"
  paused_view || { cat "$tmp/screen"; echo 'FAIL preview snapped to tail'; exit 1; }
done
echo 'ok manual page scrolling survives output changes and ticking refreshes'
tmux send-keys -t "$ui" C-f
wait_view preview-long-agent LIVE-TICK
echo 'ok ctrl-f restores follow'
# Send actual SGR mouse wheel events in the preview area.
for ((n=0;n<25;n++)); do tmux send-keys -l -t "$ui" $'\033[<64;100;15M'; done
tmux capture-pane -p -t "$ui" >"$tmp/screen"
before="$(grep 'worked ' "$tmp/screen")"
tmux send-keys -t "$long" mouse-tick Enter
wait_tick "$before"
paused_view || { cat "$tmp/screen"; echo 'FAIL mouse preview snapped to tail'; exit 1; }
echo 'ok preview mouse wheel pauses follow across refresh'
tmux send-keys -t "$ui" Down
wait_view preview-short-agent SHORT-TAIL
echo 'ok switching to an activity-free preview keeps the fixed header'
tmux send-keys -t "$ui" Up
wait_view preview-long-agent LIVE-TICK
echo 'ok focus change restores follow on the new agent'
tmux send-keys -t "$ui" C-c
