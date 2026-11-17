#!/usr/bin/env bash
# Board groups, shared states, saved model arguments and single-snapshot budget.
set -euo pipefail
here="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-board.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state/tmux-agents/test/sessions" "$tmp/state/tmux-agents/missions/project"
export XDG_STATE_HOME="$tmp/state" TMUX=/tmp/test,1,0 TMUX_PANE=%0
export BOARD_FIXTURE="$tmp/panes" BOARD_CALLS="$tmp/calls" TMUX_AGENTS_PREFIX=agents
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_CALLS"
[ "$1" = list-panes ] || exit 1
cat "$BOARD_FIXTURE"
STUB
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH"
python3 - "$tmp" <<'PY'
import sys,base64
from pathlib import Path
p=Path(sys.argv[1])
rows=[]
def row(n,name,parent='-',state='working',perm='-',tracked='1',project='project',dead='0',width='140',waiting='-'):
 rows.append(['P','%'+str(n),name,dead,perm,state,parent,'agents-'+project,'report-'+str(n),'/not-used','work:0','-',waiting,'@0','a%012x'%n,'','','','','','','0',tracked,'0','-','-','-','-',width,'40'])
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
(p/'panes').write_text('\n'.join('\t'.join(r) for r in rows)+'\n')
a=base64.b64encode(b'--model\0test-model\0').decode()
(p/'state/tmux-agents/test/sessions/a000000000001').write_text('kind=codex-profile\ncli_args='+a+'\n')
missions=p/'state/tmux-agents/missions/project'
(missions/'M3.mission').write_text('id=M3\ntitle=Mission=title\nowner=claude-project-owner\nstatus=active\ncreated=1794891234\nupdated=1794892931\nbranch=feat/board\nfuture=ignored\n')
(missions/'M4.mission').write_text('id=M4\ntitle=Offline\nowner=absent-owner\nstatus=design\ncreated=1794891234\nupdated=1794892931\n')
(missions/'M10.mission').write_text('id=M10\ntitle=Later\nowner=absent-owner\nstatus=done\ncreated=1794891234\nupdated=1794892931\n')
(missions/'board.md').write_text('| M99 | Ignore legacy | claude-project-owner | active | today |\n')

PY
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Fq 'M3 · Mission=title · active · 1794892931' "$tmp/out"
grep -Fq '  owner [claude / default] idle' "$tmp/out"
grep -Fq '    child [codex-profile / test-model] done' "$tmp/out"
grep -Fq '      grand [codex / default] needs-you' "$tmp/out"
grep -Fq 'permission [codex / default] permission' "$tmp/out"
grep -Fq 'message [codex / default] message waiting' "$tmp/out"
grep -Fq 'untracked [tool / default] -' "$tmp/out"
grep -Fq '(owner not live)' "$tmp/out"
grep -Fq 'free [codex / default] idle' "$tmp/out"
[ "$(grep -Fc 'owner [claude / default]' "$tmp/out")" = 1 ]
if grep -Eq 'outside|dead \[' "$tmp/out"; then echo 'FAIL foreign/dead agent'; exit 1; fi
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" = 1 ]
grep -q '^list-panes -a -F ' "$tmp/calls"
if grep -q 'M99' "$tmp/out"; then echo 'FAIL legacy board read'; exit 1; fi
[ "$(grep '^M[0-9]' "$tmp/out" | cut -d ' ' -f 1 | tr '\n' ' ')" = 'M3 M4 M10 ' ]
rm "$tmp/state/tmux-agents/missions/project/"*.mission
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Fq 'No mission records' "$tmp/out"
grep -Fq 'owner [claude / default]' "$tmp/out"
# A missing directory behaves like an empty record set; board.md was ignored above.
rm -rf "$tmp/state/tmux-agents/missions/project"
"$here/bin/tmux-agents" board > "$tmp/out"
grep -Fq 'No mission records' "$tmp/out"
grep -Fq 'free [codex / default]' "$tmp/out"
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
for key in (b'q', b'\x03'):
    master, slave = pty.openpty()
    process = subprocess.Popen([sys.argv[1], 'board', '--watch', '1'], stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    os.set_blocking(master, False)
    data = b''
    deadline = time.monotonic() + 10
    try:
        while b'\x1b[J' not in data and time.monotonic() < deadline:
            if select.select([master], [], [], 1)[0]:
                data += os.read(master, 65536)
        assert b'\x1b[J' in data, data
        if key == b'\x03':
            # No controlling terminal in this harness: deliver the equivalent signal.
            import signal
            process.send_signal(signal.SIGINT)
        else:
            os.write(master, key)
        deadline = time.monotonic() + 5
        while b'\x1b[?25h\x1b[?1049l' not in data and time.monotonic() < deadline:
            if select.select([master], [], [], 1)[0]:
                try:
                    chunk = os.read(master, 65536)
                    if not chunk: break
                    data += chunk
                except OSError as exc:
                    if exc.errno in (errno.EIO, errno.EAGAIN): break
                    raise
        assert b'\x1b[?25h\x1b[?1049l' in data, data
    finally:
        # macOS can keep an exiting PTY child in kernel close until the master closes.
        os.close(master)
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            raise
    assert code == (130 if key == b'\x03' else 0), (code, data)
WATCH
printf 'PASS: board grouping, states, models, missing file, width and snapshot budget\n'
