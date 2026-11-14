#!/usr/bin/env bash
# Live nearest working descendants, member traversal, focus and own-state counts.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-live-waiting-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-live-waiting.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat </dev/null
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
python3 - "$here/bin/tmux-agents" <<'PY'
import os, re, subprocess, sys
script=sys.argv[1]
def run(*args, **kw):
    return subprocess.check_output(args, text=True, **kw).strip()
def setopt(p,key,value):
    run('tmux','set','-p','-t',p,'@'+key,value)
def agent(name,parent='',member=False):
    p=run('tmux','new-window','-d','-t','work','-P','-F','#{pane_id}','cat')
    for k,v in [('agent',name),('tracked','1'),('state','done')]: setopt(p,k,v)
    if parent: setopt(p,'parent',parent)
    if member: setopt(p,'member','1')
    return p
def listing():
    env=dict(os.environ,FZF_PROMPT='all · all windows> ',TMUX_AGENTS_LIST_FIELDS='1')
    rows=run(script,'--list',env=env).split('\0')
    return {r.split('\x1f')[0].strip(): re.sub(r'\x1b\[[0-9;]*m','',''.join(r.split('\x1f')[2:])) for r in rows if '\x1f' in r}
def chip():
    return run(script,'--chip',env=dict(os.environ,CHIP_SPIN='SPIN'))
main=agent('main'); setopt(main,'state','idle')
parent=agent('p',main)
bridge=agent('b',parent,True)
worker=agent('w',bridge,True)
leaf=agent('l',worker,True)
setopt(worker,'state','working'); setopt(worker,'activity','building')
setopt(leaf,'state','working'); setopt(leaf,'activity','checking')
for state in ['idle','done','needs_you']:
    setopt(bridge,'state',state)
    rows=listing()
    assert 'idle · waiting on w' in rows[main],rows[main]
    assert 'done · waiting on w' in rows[parent],rows[parent]
    assert 'waiting on l' not in rows[parent],rows[parent]
    assert 'waiting on' not in rows[worker],rows[worker]
    print('ok nearest worker through',state,'member; working report retained')
# With bridge done, only ordinary parent is eligible for chip focus/counts.
setopt(bridge,'state','done')
s=chip()
assert 'p: done · waiting on w' in s,s
assert '✓ 1' in s and 'SPIN 1' not in s,s
setopt(parent,'state','idle'); s=chip()
assert 'p: idle · waiting on w' in s and '○ 1' in s and 'SPIN 1' not in s,s
print('ok waiting parent focus and own done/idle counts exclude working members')
setopt(parent,'state','working'); setopt(parent,'activity','reviewing'); s=chip()
assert 'p: reviewing' in s and 'waiting on' not in s and 'SPIN 1' in s,s
print('ok working parent keeps report and own working count')
setopt(parent,'state','done')
s=chip()
assert 'done · reviewing · waiting on w' in s,s
assert run('tmux','show','-pv','-t',parent,'@activity')=='reviewing'
setopt(worker,'member','0'); s=chip()
assert 'SPIN 1' in s and '✓ 1' in s,s
setopt(worker,'member','1')
print('ok waiting suffix preserves report, counts ordinary worker separately')
setopt(parent,'state','done'); setopt(parent,'activity','')
setopt(worker,'state','done')
assert 'done · waiting on l' in listing()[parent]
assert 'waiting on l' in chip()
setopt(leaf,'state','done')
assert 'waiting on' not in listing()[parent]
assert 'waiting on' not in chip()
print('ok next nearest worker replaces stopped worker, disappears when all stop')
# Siblings both appear, but a dead pane, an untracked pane and a shell do not.
setopt(worker,'state','working')
sibling=agent('s',parent,True); setopt(sibling,'state','working')
assert 'waiting on w, s' in chip()
setopt(worker,'tracked','0'); assert 'waiting on s' in chip()
setopt(sibling,'shell','1'); assert 'waiting on' not in chip()
setopt(sibling,'shell','0')
run('tmux','set','-w','-t',sibling,'remain-on-exit','on')
run('tmux','respawn-pane','-k','-t',sibling,'exit 0')
# Observe exit explicitly; never assume a fixed delay is enough.
import time
for _ in range(100):
    if run('tmux','display-message','-p','-t',sibling,'#{pane_dead}')=='1': break
    time.sleep(.02)
assert run('tmux','display-message','-p','-t',sibling,'#{pane_dead}')=='1'
assert 'waiting on' not in chip()
run('tmux','kill-pane','-t',sibling)
assert 'waiting on' not in listing()[parent]
print('ok siblings, untracked/shell/dead exclusion and vanished descendants')
# Malformed parent cycles terminate and never list an agent as its own worker.
setopt(worker,'tracked','1'); setopt(parent,'parent',worker)
rows=listing()
assert 'done · waiting on w' in rows[parent]
assert 'waiting on' not in rows[worker]
print('ok cyclic ownership terminates at nearest worker')
PY
