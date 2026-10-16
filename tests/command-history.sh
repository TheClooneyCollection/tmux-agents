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
    # Exercise the shell preflight without invoking Apple's tools or Python stub.
    import pty
    import select
    import shlex
    import time
    preflight = root / 'preflight'
    preflight.mkdir()
    apple = preflight / 'apple-python'
    apple.write_text('#!/bin/sh\necho invoked > ' + shlex.quote(str(root / 'stub-invoked')) + '\nexit 99\n')
    apple.chmod(0o700)
    xcode = preflight / 'xcode-select'
    xcode.write_text('#!/bin/sh\n[ "$1" = -p ] || exit 98\n[ -n "$FIXTURE_DEVELOPER" ] || exit 2\nprintf "%s\\n" "$FIXTURE_DEVELOPER"\n')
    xcode.chmod(0o700)
    wrapper = preflight / 'tmux-shell-history'
    wrapper.write_text(Path(helper).read_text().replace(
        '-ef /usr/bin/python3', '-ef ' + shlex.quote(str(apple))).replace(
        '/usr/bin/xcode-select', shlex.quote(str(xcode))))
    wrapper.chmod(0o700)
    private_bin = preflight / 'bin'
    private_bin.mkdir()
    private_env = dict(env, PATH=str(private_bin), FIXTURE_DEVELOPER='')
    def preflight_run():
        return subprocess.run([str(wrapper), '--pick', '--shell', 'bash', '--output',
                               str(root / 'unwritten')], env=private_env,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
    result = preflight_run()
    assert result.returncode == 127 and b'Python 3 is required' in result.stderr
    assert not result.stdout and not (root / 'unwritten').exists()
    (private_bin / 'python3').symlink_to(apple)
    result = preflight_run()
    assert result.returncode == 127 and b'Command Line Tools are missing' in result.stderr
    assert not (root / 'stub-invoked').exists()
    developer = preflight / 'developer with spaces'
    private_env['FIXTURE_DEVELOPER'] = str(developer)
    assert preflight_run().returncode == 127
    real_python = developer / 'usr/bin/python3'
    real_python.parent.mkdir(parents=True)
    real_python.symlink_to(apple)
    assert preflight_run().returncode == 127  # A selected stub is not a toolchain.
    real_python.unlink()
    real_python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
    real_python.chmod(0o700)
    (private_bin / 'dirname').symlink_to('/usr/bin/dirname')
    result = preflight_run()
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [str(preflight / 'tmux-shell-history.py').encode(),
        b'--pick', b'--shell', b'bash', b'--output', str(root / 'unwritten').encode()]
    assert not (root / 'stub-invoked').exists()
    # An actual terminal keeps the error visible until Enter, with no tmux server.
    private_env['FIXTURE_DEVELOPER'] = ''
    master, slave = pty.openpty()
    plain = subprocess.run([str(wrapper), '--shell', 'bash'], env=private_env,
                           stdin=slave, stdout=subprocess.PIPE, stderr=slave, timeout=5)
    assert plain.returncode == 127 and not plain.stdout
    child = subprocess.Popen([str(wrapper), '--pick'], env=private_env,
                             stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        visible = b''
        deadline = time.monotonic() + 5
        while b'Press Enter to close.' not in visible:
            remaining = deadline - time.monotonic()
            assert remaining > 0, visible
            ready, _, _ = select.select([master], [], [], remaining)
            assert ready, visible
            visible += os.read(master, 4096)
        assert b'Command Line Tools are missing' in visible
        assert child.poll() is None
        os.write(master, b'\n')
        assert child.wait(timeout=5) == 127
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)
    assert not (root / 'stub-invoked').exists()
    print('PASS: missing Python, Apple stub preflight, toolchain and terminal error persistence')
    print('PASS: command history formats, defaults, safety and picker (%d cases plus default-path checks)' % checks)
PY
