#!/usr/bin/env bash
# History formats and safe NUL picker protocol, using private files and fzf stubs.
# No tmux server, real user history, shell startup files or agents are used.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$here/bin/tmux-shell-history" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='tmux-command-history-') as temporary:
    root = Path(temporary)
    stub = root / 'bin'
    stub.mkdir()
    fzf = stub / 'fzf'
    fzf.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
assert '--read0' in sys.argv and '--print0' in sys.argv
assert '--print-query' in sys.argv and '--expect=alt-enter' in sys.argv
assert '--bind=enter:accept-or-print-query' in sys.argv
assert '--no-sort' in sys.argv and '--no-multi' in sys.argv
assert 'FZF_DEFAULT_OPTS' not in os.environ
assert 'FZF_DEFAULT_OPTS_FILE' not in os.environ
pathlib.Path(os.environ['CAPTURE']).write_bytes(sys.stdin.buffer.read())
sys.stdout.buffer.write(pathlib.Path(os.environ['RESPONSE']).read_bytes())
sys.exit(int(os.environ.get('STATUS', '0')))
''')
    fzf.chmod(0o700)
    env = os.environ.copy()
    for name in ('HISTFILE', 'fish_history', 'FZF_DEFAULT_OPTS_FILE'):
        env.pop(name, None)
    env.update(HOME=str(root), XDG_DATA_HOME=str(root / 'data'),
               PATH=str(stub) + os.pathsep + env['PATH'],
               CAPTURE=str(root / 'capture'), RESPONSE=str(root / 'response'),
               FZF_DEFAULT_OPTS='--preview=touch should-not-run')
    fixture = root / 'history'
    def invoke(shell='bash', pick=False, explicit=True, extra=None):
        args = [helper, '--shell', shell]
        if explicit:
            args += ['--history-file', str(fixture)]
        if pick:
            args += ['--pick', '--output', str(root / 'output')]
        child_env = dict(env)
        child_env.update(extra or {})
        return subprocess.run(args, env=child_env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)
    checks = 0
    def history(shell, raw, expected):
        global checks
        fixture.write_bytes(raw)
        before = fixture.stat().st_mtime_ns
        result = invoke(shell)
        assert result.returncode == 0, result.stderr
        assert result.stdout == b''.join(row + b'\0' for row in expected), result.stdout
        assert fixture.read_bytes() == raw and fixture.stat().st_mtime_ns == before
        checks += 1
    quote = 'printf \'%s\' "$HOME"; echo 中文'.encode()
    multiline = b'printf "first\nsecond"'
    history('bash', b'old\n' + quote + b'\nold\n', [b'old', quote])
    history('bash', b'#100\n' + multiline + b'\n#101\nnext\n#102\n' + multiline + b'\n',
            [multiline, b'next'])
    history('bash', b'good\nbad\0data\n  \n', [b'good'])
    history('fish', b'- cmd: old\n  when: 1\n- cmd: printf "first\\nsecond"\n  when: 2\n'
            b'- cmd: echo \\n literal\\\\n unknown\\q\n  paths:\n    - ignored\n- cmd: old\n',
            [b'old', b'echo \n literal\\n unknown\\q', multiline])
    history('zsh', b': 10:0;old\n: 11:2;printf "first\\\nsecond"\n: 12:0;old\n',
            [b'old', multiline])
    history('zsh', quote + b'\nplain\\\ncontinued\n', [b'plain\ncontinued', quote])
    history('zsh', b': 1:0;echo \x83\xa3\n', [b'echo \x83'])
    history('unknown', b'secret\n', [])
    # Reading never invokes a shell, its startup files or command substitutions.
    marker = root / 'executed'
    unsafe = ('touch ' + str(marker) + '; $(touch ' + str(marker) + ')').encode()
    (root / '.bashrc').write_bytes(unsafe)
    history('bash', unsafe + b'\n', [unsafe])
    assert not marker.exists()
    (root / '.bash_history').write_bytes(b'default bash\n')
    assert invoke(explicit=False).stdout == b'default bash\0'
    assert invoke(explicit=False, extra={'HISTFILE': str(fixture)}).stdout == unsafe + b'\0'
    assert invoke(explicit=False, extra={'HISTFILE': ''}).stdout == b''
    (root / '.zsh_history').write_bytes(b': 1:0;default zsh\n')
    assert invoke('/bin/zsh', explicit=False).stdout == b'default zsh\0'
    fish_dir = root / 'data/fish'
    fish_dir.mkdir(parents=True)
    (fish_dir / 'fish_history').write_bytes(b'- cmd: default fish\n')
    (fish_dir / 'private_history').write_bytes(b'- cmd: custom fish\n')
    assert invoke('fish', explicit=False).stdout == b'default fish\0'
    assert invoke('fish', explicit=False, extra={'fish_history': 'private'}).stdout == b'custom fish\0'
    assert invoke('fish', explicit=False, extra={'fish_history': ''}).stdout == b''
    fixture.unlink()
    assert invoke().stdout == b''
    fixture.write_bytes(quote + b'\n')
    output = root / 'output'
    def pick(response, expected, status=0, shell='bash'):
        global checks
        (root / 'response').write_bytes(response)
        output.write_bytes(b'untouched')
        result = invoke(shell, pick=True, extra={'STATUS': str(status)})
        assert result.returncode == (1 if expected is None else 0), result.stderr
        assert output.read_bytes() == (b'untouched' if expected is None else expected)
        checks += 1
    pick(b'printf\0\0' + quote + b'\0', quote)
    assert (root / 'capture').read_bytes() == quote + b'\0'
    pick(b'new unmatched\0', b'new unmatched')
    pick(b'new query\0alt-enter\0' + quote + b'\0', b'new query')
    pick(b'new query\0alt-enter\0', b'new query', status=1)
    pick(b'q\0\0' + multiline + b'\n\0', multiline + b'\n')
    pick(b'\0alt-enter\0' + quote + b'\0', None)
    pick(b'\0\0', None)
    pick(b'\0\0' + quote + b'\0', None, status=130)
    pick(b'broken output', None)
    pick(b'fresh\0\0fresh\0', b'fresh', shell='unknown')
    assert not marker.exists()
    print('PASS: command history formats, defaults, safety and picker (%d cases plus default-path checks)' % checks)
PY
