#!/usr/bin/env bash
# Completed reports remain visible in list/chip, with display-only prefixes.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-done-report-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-done-report.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat </dev/null
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
# No real agents are launched; both available agent commands are inert stubs.
mkdir "$tmp/stubs"
for kind in claude codex; do
  printf '#!/bin/sh\necho agent-stub\nexec cat\n' >"$tmp/stubs/$kind"
  chmod +x "$tmp/stubs/$kind"
  [ "$("$tmp/stubs/$kind" </dev/null)" = agent-stub ]
done
export TMUX_SPAWN_BIN="$tmp/stubs"
tmux set -p -t %0 @agent main
child="$(tmux new-window -d -t work -P -F '#{pane_id}' cat </dev/null)"
tmux set -p -t "$child" @agent helper
tmux set -p -t "$child" @parent %0
tmux set -p -t "$child" @tracked 1
python3 - "$B" "$child" <<'PY'
import os, re, subprocess, sys, unicodedata
b, child = sys.argv[1:]
def run(*args, **kw):
    return subprocess.check_output(args, text=True, **kw)
def setopt(key, value):
    run('tmux', 'set', '-p', '-t', child, key, value)
def width(s):
    return sum(0 if unicodedata.combining(c) or unicodedata.category(c) in ('Mn','Me','Cf') else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s)
def fit(s, n):
    if width(s) <= n: return s
    out=''
    for c in s:
        if width(out+c)>n-1: break
        out+=c
    return out+'…'
def plain(s):
    return re.sub(r'\x1b\[[0-9;]*m', '', s)
for state in ('done', 'working'):
    for report in ('', 'tests passed', '界界 é '+ '界'*30+' tail'):
        setopt('@state',state)
        setopt('@activity',report)
        env=dict(os.environ, FZF_PROMPT='agents · all windows> ', TMUX_AGENTS_LIST_FIELDS='1')
        records=run(b+'/tmux-agents','--list',env=env).split('\0')
        row=next(r for r in records if r.split('\x1f')[0].strip()==child)
        lines=plain(''.join(row.split('\x1f')[2:])).splitlines()
        lines=[line for line in lines if not line.startswith('▸ ')]
        expected=('done · '+report if state=='done' and report else report or 'no report yet')
        assert lines[1].startswith('  '+fit(expected,24)), (state,report,lines)
        # Activity ends before the fixed STATUS column even for wide glyphs.
        assert width(lines[1].split('  ')[1])<=24, lines
        chip=run(b+'/tmux-agents','--chip')
        expected_chip=('done · '+report if report else 'done') if state=='done' else report or 'starting'
        assert ': '+expected_chip+'#[default]' in chip, (state,report,chip)
        assert '#[fg=colour252]' in chip, chip
        # tmux owns chip clipping: truncating its styled line must retain prefix
        # and valid Unicode at narrow widths without modifying the source.
        visible=re.sub(r'#\[[^]]*\]', '', chip)
        run('tmux','set','-g','@done_test_chip',visible)
        clipped=run('tmux','display-message','-p','#{=30:@done_test_chip}').rstrip('\n')
        assert visible.startswith(clipped) and width(clipped)<=30, (visible,clipped)
        if report:
            assert ': '+('done · ' if state=='done' else '') in clipped, clipped
        if width(visible)>30:
            assert len(clipped)<len(visible), (visible,clipped)
        assert '\x1b[38;5;245m' in row, row
        assert run('tmux','show','-pv','-t',child,'@activity').rstrip('\n')==report
        print('ok',state,repr(report), 'list fit, chip text, stored activity')
PY
