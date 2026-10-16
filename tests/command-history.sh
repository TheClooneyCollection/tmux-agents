#!/usr/bin/env bash
# History formats and safe NUL picker protocol, using private files and fzf stubs.
# No tmux server, real user history, shell startup files or agents are used.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$here/bin/tmux-shell-history" <<'PY'
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

helper = sys.argv[1]
real_fish = shutil.which('fish')
real_fzf = shutil.which('fzf')
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
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_CONFIG_DIRS=str(root / 'config-dirs'), XDG_DATA_HOME=str(root / 'data'),
               PATH=str(stub) + os.pathsep + env['PATH'],
               CAPTURE=str(root / 'capture'), RESPONSE=str(root / 'response'),
               FZF_DEFAULT_OPTS='--preview=touch should-not-run',
               FZF_DEFAULT_OPTS_FILE=str(root / 'untrusted-fzf-options'))
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
                              stderr=subprocess.PIPE, check=False, timeout=10)
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
    history('bash', b'echo \xff\nlast without newline', [b'last without newline', b'echo \xff'])
    history('bash', b'', [])
    if real_fish:
        history(real_fish, b'- cmd: old\n  when: 1\n- cmd: printf "first\\nsecond"\n  when: 2\n'
            b'- cmd: echo \\n literal\\\\n unknown\\q\n  paths:\n    - ignored\n- cmd: old\n',
            [b'old', b'echo \n literal\\n unknown', multiline])
    history('zsh', b': 10:0;old\n: 11:2;printf "first\\\nsecond"\n: 12:0;old\n',
            [b'old', multiline])
    history('zsh', quote + b'\nplain\\\ncontinued\n', [b'plain\ncontinued', quote])
    history('zsh', b': 1:0;echo \x83\xa3\n', [b'echo \x83'])
    history('unknown', b'secret\n', [])
    # Bash/zsh history is data; neither startup files nor commands are evaluated.
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
    if real_fish:
        assert invoke(real_fish, explicit=False).stdout == b'default fish\0'
        assert invoke(real_fish, explicit=False, extra={'fish_history': 'private'}).stdout == b'custom fish\0'
        assert invoke(real_fish, explicit=False, extra={'fish_history': ''}).stdout == b''
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
    # Malformed fields, empty commands and unsafe destinations never overwrite.
    pick(b' \t\n\0', None)
    pick(b'q\0\0good\0injected\0', None)
    pick(b'q\0unknown-key\0good\0', None)
    pick(b'q\0\0good', None)
    pick(b'q\0\0good\0', None, status=2)
    pick(b'q\0\0good\0', b'good')
    assert output.stat().st_mode & 0o777 == 0o600
    output.unlink()
    (root / 'response').write_bytes(b'brand new\0')
    assert invoke(pick=True).returncode == 0
    assert output.read_bytes() == b'brand new'
    assert output.stat().st_mode & 0o777 == 0o600
    output.unlink()
    protected = root / 'protected'
    protected.write_bytes(b'protected data')
    output.symlink_to(protected)
    result = invoke(pick=True)
    assert result.returncode == 1 and b'cannot write selection' in result.stderr
    assert protected.read_bytes() == b'protected data' and output.is_symlink()
    output.unlink()
    # Stub a configured fish path, not a parser: assert the native command and
    # session environment, and emit already-unescaped, newest-first NUL records.
    import json
    fish_bin = root / 'configured shell'
    fish_bin.mkdir()
    fish = fish_bin / 'fish'
    fish.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['FISH_CAPTURE'])
args = sys.argv[1:]
assert args in (['-c', 'history --null'], ['--no-config', '-c', 'history --null'])
record = {'args': args, 'session': os.environ.get('fish_history')}
if '--no-config' in args:
    path = pathlib.Path(os.environ['XDG_DATA_HOME']) / 'fish/tmux_agents_history_history'
    record['history'] = path.read_bytes().hex() if path.exists() else ''
    record['config'] = os.environ['XDG_CONFIG_HOME']
root.write_text(json.dumps(record))
if os.environ.get('FISH_FAILURE'):
    print('fixture fish failed', file=sys.stderr)
    sys.exit(7)
sys.stdout.buffer.write(pathlib.Path(os.environ['FISH_RESPONSE']).read_bytes())
''')
    fish.chmod(0o700)
    fish_capture = root / 'fish-capture'
    fish_response = root / 'fish-response'
    native_rows = quote + b'\0' + multiline + b'\0'
    fish_response.write_bytes(native_rows)
    env.update(FISH_CAPTURE=str(fish_capture), FISH_RESPONSE=str(fish_response))
    assert invoke(str(fish), explicit=False).stdout == native_rows
    assert json.loads(fish_capture.read_text()) == {'args': ['-c', 'history --null'], 'session': None}
    assert invoke(str(fish), explicit=False, extra={'fish_history': 'private'}).stdout == native_rows
    assert json.loads(fish_capture.read_text())['session'] == 'private'
    fish_capture.unlink()
    assert invoke(str(fish), explicit=False, extra={'fish_history': ''}).stdout == b''
    assert not fish_capture.exists()
    fixture.write_bytes(b'- cmd: fixture only\n  when: 1\n')
    assert invoke(str(fish), extra={'fish_history': ''}).stdout == native_rows
    recorded = json.loads(fish_capture.read_text())
    assert recorded['args'] == ['--no-config', '-c', 'history --null']
    assert recorded['session'] == 'tmux_agents_history'
    assert bytes.fromhex(recorded['history']) == fixture.read_bytes()
    assert recorded['config'] != env['XDG_CONFIG_HOME']
    assert not Path(recorded['config']).parent.exists(), 'private history directory leaked'
    result = invoke(str(fish), explicit=False, extra={'FISH_FAILURE': '1'})
    assert result.returncode == 1 and not result.stdout
    assert b'cannot read fish history' in result.stderr and b'fixture fish failed' in result.stderr
    # Real fish loads noninteractive config, including a replacement history
    # function. Explicit files bypass it and never modify the source file.
    if real_fish:
        config = root / 'config/fish'
        config.mkdir(parents=True, exist_ok=True)
        (config / 'config.fish').write_text("function history\n    printf 'config-owned\\0'\nend\n")
        assert invoke(real_fish, explicit=False).stdout == b'config-owned\0'
        assert invoke(real_fish, explicit=False, extra={'fish_history': ''}).stdout == b''
        history(real_fish, b'- cmd: old\n  when: 1\n- cmd: ' + quote + b'\n  when: 2\n', [quote, b'old'])
        (config / 'config.fish').unlink()
        print('PASS: real fish history format, sessions and config/file override semantics')
    else:
        print('SKIP: real fish is not installed (configured fish stub checks passed)')
    # A private terminal proves fish errors persist until Enter. No tmux needed.
    import fcntl
    import pty
    import select
    import struct
    import termios
    import time
    master, slave = pty.openpty()
    error_env = dict(env, FISH_FAILURE='1')
    plain = subprocess.run([helper, '--shell', str(fish)], env=error_env,
                           stdin=slave, stdout=subprocess.PIPE, stderr=slave, timeout=5)
    assert plain.returncode == 1 and not plain.stdout
    child = subprocess.Popen([helper, '--pick', '--shell', str(fish), '--output', str(output)],
                             env=error_env, stdin=slave, stdout=slave, stderr=slave)
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
        assert b'cannot read fish history' in visible
        assert child.poll() is None
        os.write(master, b'\n')
        assert child.wait(timeout=5) == 1
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)
    print('PASS: fish builtin invocation, isolation, errors and terminal persistence')
    # Real fzf on its own controlling PTY. --sync loads the complete fixture;
    # a result binding signals completed filtering, never an arbitrary sleep.
    if real_fzf:
        import shlex
        terminal_bin = root / 'terminal-bin'
        terminal_bin.mkdir()
        ready_file = root / 'fzf-ready'
        query_ready = root / 'fzf-query-ready'
        driver = terminal_bin / 'fzf'
        def terminal_pick(keys, expected, raw=quote + b'\n', new_query=None, accept=b'\r'):
            fixture.write_bytes(raw)
            output.write_bytes(b'untouched')
            ready_file.unlink(missing_ok=True)
            query_ready.unlink(missing_ok=True)
            child_env = dict(env, PATH=str(terminal_bin) + os.pathsep + os.environ['PATH'],
                             TERM='xterm-256color', SHELL='/bin/sh')
            event = 'result:execute-silent(printf ready > ' + shlex.quote(str(ready_file))
            if new_query:
                event += '; if [ {q} = ' + shlex.quote(new_query) + ' ]; then printf ready > ' + shlex.quote(str(query_ready)) + '; fi'
            event += ')'
            driver.write_text('#!/bin/sh\nexec ' + shlex.quote(real_fzf) +
                              ' --sync --bind ' + shlex.quote(event) + ' "$@"\n')
            driver.chmod(0o700)
            pid, master = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
                os.execve(helper, [helper, '--shell', 'bash', '--history-file', str(fixture),
                                  '--pick', '--output', str(output)], child_env)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
            visible = b''
            exited = False
            try:
                deadline = time.monotonic() + 10
                while not ready_file.exists():
                    assert time.monotonic() < deadline, visible
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        chunk = os.read(master, 65536)
                        assert chunk, visible
                        visible += chunk
                os.write(master, keys)
                if new_query:
                    while not query_ready.exists():
                        assert time.monotonic() < deadline, visible
                        ready, _, _ = select.select([master], [], [], 0.05)
                        if ready:
                            visible += os.read(master, 65536)
                    os.write(master, accept)
                while True:
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done:
                        exited = True
                        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == (1 if expected is None else 0), visible
                        break
                    assert time.monotonic() < deadline, visible
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        try:
                            visible += os.read(master, 65536)
                        except OSError:
                            pass
                assert output.read_bytes() == (b'untouched' if expected is None else expected)
            finally:
                if not exited:
                    os.killpg(pid, 9)
                    os.waitpid(pid, 0)
                os.close(master)
        terminal_pick(b'\r', quote)
        terminal_pick(b'new unmatched', b'new unmatched', new_query='new unmatched')
        terminal_pick(b'new unmatched', b'new unmatched', new_query='new unmatched', accept=b'\x1b\r')
        terminal_pick(b'printf\x1b\r', b'printf')
        terminal_pick(b'\x1b\r', None)
        terminal_pick(b'\x1b', None)
        terminal_pick(b'\r', multiline, raw=b'#100\n' + multiline + b'\n')
        print('PASS: real fzf PTY Enter, unmatched query, Alt-Enter, Esc and multiline selection')
    else:
        print('SKIP: real fzf is not installed (protocol stub checks passed)')
    print('PASS: command history formats, defaults, safety and picker (%d cases plus default-path checks)' % checks)
PY
