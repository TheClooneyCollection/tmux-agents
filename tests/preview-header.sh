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
cleanup() { [ ! -s "$tmp/picker-errors" ] || cat "$tmp/picker-errors" >&2; cleanup_test_server || return; rm -rf "$tmp"; }
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
tmux set -p -t "$long" @tracked 1; tmux set -p -t "$long" @state working
tmux set -p -t "$long" @worked 0
tmux set -p -t "$long" @turn_start "$(date +%s)"
tmux set -p -t "$long" @activity '长活动 needs to stay visible while the pane output follows its last line'
tmux set -p -t "$short" @agent preview-short-agent
# Keep this capture shorter than the preview body (avoid trailing blank rows).
tmux resize-window -t "$(tmux display -p -t "$short" '#{window_id}')" -y 8
mkdir "$tmp/shim"
: >"$tmp/polls"
: >"$tmp/actions"
export PREVIEW_ROOT="$tmp" PREVIEW_FZF="$real_fzf" PREVIEW_LONG="$long" PREVIEW_SHORT="$short"
PREVIEW_SLEEP="$(command -v sleep)"
export PREVIEW_SLEEP
for var in PREVIEW_ROOT PREVIEW_FZF PREVIEW_LONG PREVIEW_SHORT PREVIEW_SLEEP; do
  tmux set-environment -g "$var" "${!var}"
done
cat >"$tmp/shim/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >"$PREVIEW_ROOT/sleep-pid"
printf '.\n' >>"$PREVIEW_ROOT/polls"
exec "$PREVIEW_SLEEP" "$@"
SH
cat >"$tmp/shim/fzf" <<'SH'
#!/bin/sh
exec python3 "$PREVIEW_ROOT/filter.py" "$@"
SH
cat >"$tmp/with-shell" <<'SH'
#!/bin/sh
printf '%s\n' "$2" >>"$PREVIEW_ROOT/actions"
exec bash "$@"
SH
cat >"$tmp/filter.py" <<'PYTEST'
import os,pathlib,sys
root=pathlib.Path(os.environ['PREVIEW_ROOT'])
args=sys.argv[1:]
preview=args[args.index('--preview')+1]
window=next(a for a in args if a.startswith('--preview-window='))
assert window=='--preview-window=right,55%,follow,~7',window
root.joinpath('rows').write_text(os.environ['PREVIEW_LONG']+'\n'+os.environ['PREVIEW_SHORT']+'\n')
root.joinpath('state-dir').write_text(os.environ.get('TMUX_AGENTS_PREVIEW_DIR',''))
binds=[]
for i,arg in enumerate(args[:-1]):
    if arg!='--bind': continue
    value=args[i+1]
    assert 'page-up:' not in value and 'page-down:' not in value, value
    if value.startswith('start:'):
        # Same production refresh-loop startup; static rows need no reload.
        value='start:execute-silent'+value.split('+execute-silent',1)[1]
    elif not value.startswith(('focus:','f11:','f12:','shift-up:','alt-up:','preview-scroll-up:','shift-scroll-up:','ctrl-f:')):
        continue
    if 'change-preview-window' in value:
        for spec in value.split('change-preview-window(')[1:]: assert '~7' in spec.split(')',1)[0],value
    binds.extend(['--bind',value])
os.dup2(os.open(root/'rows',os.O_RDONLY),0)
os.execv(os.environ['PREVIEW_FZF'],[os.environ['PREVIEW_FZF'],'--listen','--with-shell',str(root/'with-shell')+' -c','--layout=reverse','--preview',preview,window,*binds])
PYTEST
chmod +x "$tmp/shim/fzf" "$tmp/shim/sleep" "$tmp/with-shell"
# Keep the actual picker parent, startup and EXIT cleanup; inject only static
# rows and the production preview bindings into real fzf.
ui="$(tmux new-window -d -P -F '#{pane_id}' "PATH='$tmp/shim:$PATH' '$B/tmux-agents' 2>'$tmp/picker-errors'")"
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
# Check exact visible rows, including screen line numbers: an offset drift can
# still show old BODY rows, so merely checking that LIVE-TICK is absent is weak.
body_view() { grep -n -o 'BODY-ROW-[0-9]*' "$tmp/screen"; }
# Initial focus and Ctrl-F can both schedule a preview alongside the timer.
# Observe a fresh completed ticking frame before issuing the first scroll;
# This deliberately tests the steady-state guarantee. The accepted fzf 0.65
# in-flight first-scroll limitation and its immediate-scroll reproduction are
# recorded in docs/decisions/2026-10-05-list-layout-and-worked-time.md.
wait_live_frame() {
  local previous i
  previous="$(grep 'worked ' "$tmp/screen")"
  for ((i=0;i<100;i++)); do
    tmux capture-pane -p -t "$ui" >"$tmp/screen"
    if [ "$(grep 'worked ' "$tmp/screen")" != "$previous" ] && grep -q 'BODY-ROW' "$tmp/screen"; then return 0; fi
    sleep .05
  done
  echo 'FAIL live preview did not tick' >&2
  return 1
}
wait_body_change() {
  local previous="$1" i
  for ((i=0;i<100;i++)); do
    tmux capture-pane -p -t "$ui" >"$tmp/screen"
    [ "$(body_view)" = "$previous" ] || return 0
    sleep .05
  done
  printf 'FAIL scroll did not move (%s)\nPrevious:\n%s\n' "${key:-initial}" "$previous" >&2
  cat "$tmp/screen" >&2
  return 1
}
wait_polls() {
  local target="$1" i
  for ((i=0;i<150;i++)); do
    [ "$(wc -l <"$tmp/polls")" -lt "$target" ] || return 0
    sleep .05
  done
  echo 'FAIL preview loop stopped polling' >&2
  return 1
}
assert_stable() {
  local expected actual before actions
  expected="$(body_view)"
  [ -n "$expected" ]
  cp "$tmp/screen" "$tmp/frozen"
  actions="$(wc -l <"$tmp/actions")"
  before="$(wc -l <"$tmp/polls")"
  tmux send-keys -t "$long" "tick-$before" Enter
  # Explicitly observe three production loop intervals, not a fixed delay.
  wait_polls "$((before+3))"
  tmux capture-pane -p -t "$ui" >"$tmp/screen"
  actual="$(body_view)"
  [ "$actual" = "$expected" ] || { printf 'FAIL exact preview offset drift\nBefore:\n%s\nAfter:\n%s\n' "$expected" "$actual"; exit 1; }
  cmp "$tmp/frozen" "$tmp/screen" || { echo 'FAIL paused preview changed'; exit 1; }
  [ "$(wc -l <"$tmp/actions")" -eq "$actions" ] || { echo 'FAIL paused preview launched a shell'; exit 1; }
}
wait_live_frame
previous="$(body_view)"
tmux send-keys -t "$ui" M-Up
wait_body_change "$previous"
assert_stable
echo 'ok exact half-page-scroll content and offset stay frozen across output and timer ticks'
# Every subsequent key must keep accumulating its native movement, with no
# shell and no repeated change-preview-window resetting the offset.
for key in S-Up S-Down M-Up M-Down; do
  previous="$(body_view)"
  actions="$(wc -l <"$tmp/actions")"
  tmux send-keys -t "$ui" "$key"
  wait_body_change "$previous"
  [ "$(wc -l <"$tmp/actions")" -eq "$actions" ] || { echo "FAIL shell per $key"; exit 1; }
done
assert_stable
tmux send-keys -t "$ui" C-f
wait_view preview-long-agent LIVE-TICK
echo 'ok ctrl-f explicitly refreshes and restores follow'
# Send actual SGR mouse wheel events in the preview area. fzf 0.65.2's
# PreviewScrollUp default is actPreviewUp, exactly one line per event.
wait_live_frame
previous="$(body_view)"
tmux send-keys -l -t "$ui" $'\033[<64;100;15M'
wait_body_change "$previous"
# A second wheel event must move exactly one row, not rebuild the geometry.
first="$(grep -o 'BODY-ROW-[0-9]*' "$tmp/screen" | head -1)"
actions="$(wc -l <"$tmp/actions")"
previous="$(body_view)"
tmux send-keys -l -t "$ui" $'\033[<64;100;15M'
wait_body_change "$previous"
second="$(grep -o 'BODY-ROW-[0-9]*' "$tmp/screen" | head -1)"
[ "$((10#${first##*-}-10#${second##*-}))" -eq 1 ] || { echo "FAIL native wheel step: $first -> $second"; exit 1; }
[ "$(wc -l <"$tmp/actions")" -eq "$actions" ] || { echo 'FAIL shell per wheel tick'; exit 1; }
assert_stable
echo 'ok native one-line wheel movement and exact frozen content without per-tick processes'
tmux send-keys -t "$ui" NPage
wait_view preview-short-agent SHORT-TAIL
echo 'ok native PageDown navigates the list and keeps the fixed header'
tmux send-keys -t "$ui" PPage
wait_view preview-long-agent LIVE-TICK
echo 'ok native PageUp navigates the list and focus change restores follow'
# Focus must rearm first-scroll pause as well as resume follow.
wait_live_frame
previous="$(body_view)"
tmux send-keys -t "$ui" M-Up
wait_body_change "$previous"
assert_stable
state_dir="$(cat "$tmp/state-dir")"
read -r loop_pid <"$state_dir/loop"
read -r sleep_pid <"$tmp/sleep-pid"
tmux send-keys -t "$ui" C-c
for ((i=0;i<100;i++)); do
  if [ ! -e "$state_dir" ] && ! kill -0 "$loop_pid" 2>/dev/null && ! kill -0 "$sleep_pid" 2>/dev/null; then
    echo 'ok picker exit while paused removes owned files and stops refresh loop'
    exit 0
  fi
  sleep .05
done
echo 'FAIL picker cleanup leaked state or refresh process' >&2
exit 1
