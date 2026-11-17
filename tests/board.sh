#!/usr/bin/env bash
# Board groups, shared states, saved model arguments and single-snapshot budget.
set -euo pipefail
here="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-board.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state/tmux-agents/test/sessions" "$tmp/state/tmux-agents/missions/project"
BOARD_REAL_TMUX="$(command -v tmux)"
export BOARD_REAL_TMUX
BOARD_REAL_BASENAME="$(command -v basename)"
export BOARD_REAL_BASENAME
BOARD_REAL_GIT="$(command -v git)"
export BOARD_REAL_GIT
mkdir -p "$tmp/project"
"$BOARD_REAL_GIT" -C "$tmp/project" init -q
"$BOARD_REAL_GIT" -C "$tmp/project" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
"$BOARD_REAL_GIT" -C "$tmp/project" worktree add -qb linked "$tmp/linked" >/dev/null
cd "$tmp/project"
export XDG_STATE_HOME="$tmp/state" TMUX=/tmp/test,1,0 TMUX_PANE=%0
unset TMUX_AGENTS_PREFIX
export BOARD_FIXTURE="$tmp/panes" BOARD_CALLS="$tmp/calls" BOARD_GIT_CALLS="$tmp/git-calls"
export BOARD_FAIL_ONCE="$tmp/fail-once"
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_CALLS"
if [ "$1" = show-option ]; then printf 'agents\n'; exit 0; fi
[ "$1" = list-panes ] || exit 1
if [ -f "$BOARD_FAIL_ONCE" ]; then rm "$BOARD_FAIL_ONCE"; exit 1; fi
cat "$BOARD_FIXTURE"
STUB
cat > "$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_GIT_CALLS"
exec "$BOARD_REAL_GIT" "$@"
STUB
cat > "$tmp/bin/basename" <<'STUB'
#!/usr/bin/env bash
[ "${BOARD_NO_PROJECT:-0}" = 1 ] && exit 0
exec "$BOARD_REAL_BASENAME" "$@"
STUB
chmod +x "$tmp/bin/tmux" "$tmp/bin/git" "$tmp/bin/basename"
export PATH="$tmp/bin:$PATH"
python3 - "$tmp" <<'PY'
import sys,base64
from pathlib import Path
p=Path(sys.argv[1])
rows=[]
def row(n,name,parent='-',state='working',perm='-',tracked='1',project='project',dead='0',width='140',waiting='-'):
 rows.append(['P','%'+str(n),name,dead,perm,state,parent,'agents-'+project,'report-'+str(n),str(p/'project'),'work:0','-',waiting,'@0','a%012x'%n,'','','','','','','0',tracked,'0','-','-','-','-',width,'40'])
row(0,'claude-project-owner',parent='%9',state='idle')
row(9,'claude-project-main',state='idle')
row(1,'codex-project-child','%0',state='done')
row(2,'codex-project-grand','%1',state='needs_you')
row(3,'codex-project-free',state='idle')
row(4,'codex-project-permission','%0',perm='123')
row(5,'tool-project-untracked',tracked='0')
row(6,'codex-other-outside',project='other')
row(7,'codex-project-dead',dead='1')
row(8,'codex-project-message','%0',waiting='123')
# A direct child remains unassigned when it works in another directory.
row(10,'claude-project-designer','%9',state='idle')
rows[-1][7]='work'; rows[-1][9]=str(p/'elsewhere')
# A visible worktree pane shares the main repository's project.
row(13,'codex-project-linked',state='idle')
rows[-1][7]='work'; rows[-1][9]=str(p/'linked')
# Mission ownership follows pane links regardless of child cwd or session.
row(11,'claude-project-interface', '%9',state='idle')
row(12,'codex-project-worker','%11',state='idle')
rows[-1][7]='work'; rows[-1][9]=str(p/'elsewhere')
# An unreadable pane cwd must not inherit the board process's PWD.
row(14,'codex-project-empty-path',state='idle')
rows[-1][7]='work'; rows[-1][9]=''
(p/'panes').write_text('\n'.join('\t'.join(r) for r in rows)+'\n')
a=base64.b64encode(b'--model\0test-model\0').decode()
(p/'state/tmux-agents/test/sessions/a000000000001').write_text('kind=codex-profile\ncli_args='+a+'\n')
missions=p/'state/tmux-agents/missions/project'
(missions/'M3.mission').write_text('id=M3\ntitle=Mission=title\nowner=claude-project-owner\nstatus=active\ncreated=1794891234\nupdated=1794892931\nbranch=feat/board\nfuture=ignored\n')
(missions/'M4.mission').write_text('id=M4\ntitle=Offline\nowner=claude-project-interface\nstatus=design\ncreated=1794891234\nupdated=1794892931\n')
(missions/'M10.mission').write_text('id=M10\ntitle=Later\nowner=absent-owner\nstatus=done\ncreated=1794891234\nupdated=1794892931\n')
(missions/'board.md').write_text('| M99 | Ignore legacy | claude-project-owner | active | today |\n')

PY
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Eq '^M3 · Mission=title · active · [0-9]+[smhd] ago$' "$tmp/out"
grep -Fq '  owner [claude / default] idle' "$tmp/out"
grep -Fq '    child [codex-profile / test-model] done' "$tmp/out"
grep -Fq '      grand [codex / default] needs-you' "$tmp/out"
grep -Fq 'permission [codex / default] permission' "$tmp/out"
grep -Fq 'message [codex / default] message waiting' "$tmp/out"
grep -Fq 'untracked [tool / default] -' "$tmp/out"
grep -Fq '(owner not live)' "$tmp/out"
grep -Fq 'free [codex / default] idle' "$tmp/out"
[ "$(grep -Fc 'owner [claude / default]' "$tmp/out")" = 1 ]
if grep -Eq 'empty-path|outside|dead \[' "$tmp/out"; then echo 'FAIL foreign/dead agent'; exit 1; fi
[ "$(grep -c '^list-panes ' "$tmp/calls")" = 1 ]
[ "$(grep -c '^show-option ' "$tmp/calls")" = 1 ]
grep -q '^list-panes -a -F ' "$tmp/calls"
if grep -q 'M99' "$tmp/out"; then echo 'FAIL legacy board read'; exit 1; fi
[ "$(grep '^M[0-9]' "$tmp/out" | cut -d ' ' -f 1 | tr '\n' ' ')" = 'M3 M4 M10 ' ]
# Worktree invocation reads exactly the CLI's main-project records.
(
 cd "$tmp/linked"
 "$here/bin/tmux-agents" mission show M3 --from test > "$tmp/mission-out"
 TMUX_PANE=%13 "$here/bin/tmux-agents" board > "$tmp/linked-out"
)
grep -Fq 'Mission=title' "$tmp/mission-out"
grep -Fq "M3 · Mission=title · active" "$tmp/linked-out"
python3 - "$tmp/out" <<'GROUPS'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
assert 'claude-project-designer [claude / default]' in s.split('unassigned')[1], s
assert 'linked [codex / default]' in s.split('unassigned')[1], s
m4=s.split('M4 ·')[1].split('M10 ·')[0]
assert '  interface [claude / default]' in m4, m4
assert '    codex-project-worker [codex / default]' in m4, m4
GROUPS
rm "$tmp/state/tmux-agents/missions/project/"*.mission
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Fq 'No mission records' "$tmp/out"
grep -Fq 'owner [claude / default]' "$tmp/out"
# A missing directory behaves like an empty record set; board.md was ignored above.
rm -rf "$tmp/state/tmux-agents/missions/project"
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Fq 'No mission records' "$tmp/out"
grep -Fq 'free [codex / default]' "$tmp/out"
# Home project labels use home, while agent naming uses ~.
python3 - "$tmp/panes" "$tmp/home-panes" <<'PYHOME'
from pathlib import Path
import sys
r=Path(sys.argv[1]).read_text().splitlines()[0].split('\t')
r[2]='claude-~-owner'; r[7]='agents-home'
Path(sys.argv[2]).write_text('\t'.join(r)+'\n')
PYHOME
(cd "$HOME"; BOARD_FIXTURE="$tmp/home-panes" "$here/bin/tmux-agents" board) > "$tmp/out"
grep -Fq 'owner [claude / default]' "$tmp/out"
if grep -Fq 'claude-~-owner' "$tmp/out"; then echo 'FAIL home prefix'; exit 1; fi
# Width follows the current pane on each invocation, including UTF-8 truncation.
python3 - "$tmp/panes" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); rows=[r.split('\t') for r in p.read_text().splitlines()]
for r in rows:r[28]='24'
p.write_text('\n'.join('\t'.join(r) for r in rows)+'\n')
PY
"$here/bin/tmux-agents" board > "$tmp/out"
python3 - "$tmp/out" <<'PY'
import sys
assert all(len(s.rstrip('\n'))<=24 for s in open(sys.argv[1]))
PY
for arg in 0 -1 abc; do
 if "$here/bin/tmux-agents" board --watch "$arg" > /dev/null 2>&1; then echo "FAIL accepted interval $arg"; exit 1; fi
done
if "$here/bin/tmux-agents" board --watch </dev/null > /dev/null 2>&1; then echo 'FAIL watch without tty'; exit 1; fi
"$here/bin/tmux-agents" board --help | grep -q 'usage:'
# Exercise watch on a pseudo-terminal; wait for the actual frame before quitting.
python3 - "$here/bin/tmux-agents" <<'WATCH'
import errno, os, pty, select, subprocess, sys, time
from pathlib import Path
# Visible panes force project resolution; all share one path.
fixture=Path(os.environ['BOARD_FIXTURE'])
rows=[r.split('\t') for r in fixture.read_text().splitlines()]
for r in rows:
    r[7]='work'; r[28]='140'
    if r[9]: r[9]=os.getcwd()
fixture.write_text('\n'.join('\t'.join(r) for r in rows)+'\n')
full=subprocess.check_output([sys.argv[1], 'board'], text=True).splitlines()
assert not any('more rows' in line or 'empty-path' in line for line in full), full
# An unresolved project prints one line, including on each watch refresh.
expected = f"board: cannot resolve a project for {os.getcwd()}"
no_project_env = dict(os.environ, BOARD_NO_PROJECT='1')
result = subprocess.run([sys.argv[1], 'board'], env=no_project_env, text=True, capture_output=True)
assert (result.returncode, result.stdout, result.stderr) == (0, expected+'\n', ''), result
# The renderer also handles an absent mission-directory environment value.
renderer_env = dict(os.environ)
renderer_env.pop('BOARD_MISSION_DIR', None)
renderer = str(Path(sys.argv[1]).with_name('tmux-agents-board.pl'))
result = subprocess.run(['perl', renderer, str(Path(renderer).parent)], env=renderer_env, text=True, capture_output=True)
assert (result.returncode, result.stdout, result.stderr) == (0, expected+'\n', ''), result
for key, height in ((b'q', 8), (b'q', len(full)+1), (b'\x03', 40), (b'q', 0)):
    no_project = height == 0
    for r in rows: r[29]=str(height)
    fixture.write_text('\n'.join('\t'.join(r) for r in rows)+'\n')
    Path(os.environ['BOARD_CALLS']).write_text('')
    Path(os.environ['BOARD_GIT_CALLS']).write_text('')
    if key == b'q' and not no_project: Path(os.environ['BOARD_FAIL_ONCE']).touch()
    master, slave = pty.openpty()
    process = subprocess.Popen([sys.argv[1], 'board', '--watch', '1'], stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=no_project_env if no_project else None, start_new_session=True)
    os.close(slave)
    os.set_blocking(master, False)
    data = b''
    deadline = time.monotonic() + 10
    try:
        frames = 3 if key == b'q' else 1
        while data.count(b'\x1b[J') < frames and time.monotonic() < deadline:
            if select.select([master], [], [], 1)[0]:
                data += os.read(master, 65536)
        assert data.count(b'\x1b[J') >= frames, data
        if key == b'q' and not no_project:
            assert b'board: refresh failed (retrying)' in data, data
            assert b'Mission board' in data, data
        frame=data.split(b'\x1b[H\x1b[2J\x1b[3J')[-1].split(b'\x1b[J')[0]
        lines=[line.replace(b'\x1b[K', b'').rstrip(b'\r').decode() for line in frame.split(b'\n') if line]
        if no_project:
            rendered = data.split(b'\x1b[H\x1b[2J\x1b[3J')[1:]
            assert len(rendered) >= frames, data
            for refresh in rendered:
                assert refresh.split(b'\x1b[J')[0] == expected.encode()+b'\x1b[K\r\n', refresh
            assert process.poll() is None, data
        else:
            assert not any('more rows' in line for line in lines), lines
            assert lines == full, (height, lines, full)
        calls=Path(os.environ['BOARD_CALLS']).read_text().splitlines()
        assert sum(c.startswith('show-option ') for c in calls)==1, calls
        if not no_project:
            assert sum(c.startswith('list-panes ') for c in calls)>=frames, calls
        assert all(c.startswith(('show-option ', 'list-panes ')) for c in calls), calls
        git_calls=Path(os.environ['BOARD_GIT_CALLS']).read_text().splitlines()
        assert len(git_calls)==(2 if no_project else 4), git_calls
        if key == b'\x03':
            # No controlling terminal in this harness: deliver the equivalent signal.
            import signal
            process.send_signal(signal.SIGINT)
        else:
            os.write(master, key)
        deadline = time.monotonic() + 5
        while b'\x1b[?25h' not in data and time.monotonic() < deadline:
            if select.select([master], [], [], 1)[0]:
                try:
                    chunk = os.read(master, 65536)
                    if not chunk: break
                    data += chunk
                except OSError as exc:
                    if exc.errno in (errno.EIO, errno.EAGAIN): break
                    raise
        assert b'\x1b[?25h' in data, data
    finally:
        # macOS can keep an exiting PTY child in kernel close until the master closes.
        os.close(master)
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            raise
    assert code == (130 if key == b'\x03' else 0), (code, data)
    assert process.stderr.read() == b'', data
    assert b'\x1b[?1049' not in data, data
# A real, private tmux server verifies scrollback rather than only PTY bytes.
import shlex
socket = 'tmux-board-history-' + str(os.getpid())
tmux = [os.environ['BOARD_REAL_TMUX'], '-L', socket]
server_env = dict(os.environ)
server_env.pop('TMUX', None)
server_env.pop('TMUX_PANE', None)
def control(*args):
    return subprocess.check_output(tmux + list(args), env=server_env, text=True)
def wait_for(read, ready):
    deadline = time.monotonic() + 10
    value = read()
    while not ready(value) and time.monotonic() < deadline:
        time.sleep(.02)
        value = read()
    assert ready(value), value
    return value
script = fixture.parent / 'watch-history.sh'
script.write_text('export ' + ' '.join(k+'='+shlex.quote(v) for k,v in os.environ.items()
                  if k.startswith('BOARD_') or k in ('PATH', 'XDG_STATE_HOME')) + '\n' +
                  'cd ' + shlex.quote(os.getcwd()) + '\n' +
                  shlex.quote(sys.argv[1]) + ' board --watch 1\n' +
                  "printf 'BOARD-EXIT:%s\\n' \"$?\"\nexec cat\n")
try:
    control('-f', '/dev/null', 'new-session', '-d', '-s', 'board', '-x', '140', '-y', '8', 'exec cat')
    control('has-session')
    socket_path = control('display-message', '-p', '#{socket_path}').strip()
    assert socket_path and not socket_path.endswith('/default'), socket_path
    control('set-option', '-g', 'default-shell', '/bin/sh')
    control('respawn-pane', '-k', '-t', 'board:0.0', '/bin/sh ' + shlex.quote(str(script)))
    capture = lambda: control('capture-pane', '-p', '-t', 'board:0.0', '-S', '-')
    screen = wait_for(capture, lambda s: full[-1] in s)
    assert 'Mission board · project' in screen, screen
    assert int(control('display-message', '-p', '-t', 'board:0.0', '#{history_size}')) > 0, screen
    assert control('display-message', '-p', '-t', 'board:0.0', '#{alternate_on}').strip() == '0'
    # A later frame replaces scrollback instead of accumulating old boards.
    fixture.write_text(fixture.read_text().replace('report-0', 'updated-report-0'))
    screen = wait_for(capture, lambda s: 'updated-report-0' in s and full[-1] in s)
    assert screen.count('Mission board · project') == 1, screen
    control('copy-mode', '-t', 'board:0.0')
    control('send-keys', '-t', 'board:0.0', '-X', 'history-top')
    assert int(control('display-message', '-p', '-t', 'board:0.0', '#{scroll_position}')) > 0
    control('send-keys', '-t', 'board:0.0', '-X', 'cancel')
    control('send-keys', '-t', 'board:0.0', 'q')
    wait_for(capture, lambda s: 'BOARD-EXIT:0' in s)
    assert control('display-message', '-p', '-t', 'board:0.0', '#{cursor_flag}').strip() == '1'
finally:
    subprocess.run(tmux + ['kill-server'], env=server_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
WATCH
printf 'PASS: board grouping, states, models, missing file, width and snapshot budget\n'
