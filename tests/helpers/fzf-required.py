"""Exercise missing-fzf automation and an actual tmux popup on a private server."""
import fcntl
import os
import pty
import select
import shlex
import struct
import subprocess
import sys
import termios
import time

here, tmp, sock = sys.argv[1:]
env = dict(os.environ, PATH=tmp + '/path')
command = [here + '/bin/tmux-agents']
for data in (None, b'piped input\n'):
    result = subprocess.run(command, env=env, input=data,
                            stdin=subprocess.DEVNULL if data is None else None,
                            capture_output=True, timeout=5, check=False)
    assert result.returncode == 1, result
    assert b'brew install fzf' in result.stderr, result
    assert b'Press any key' not in result.stderr, result
for option in ('--list', '--status', '--chip'):
    result = subprocess.run(command + [option], env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=5, check=False)
    assert result.returncode == 0, (option, result)
    assert b'fzf is required' not in result.stderr, result
print('ok    devnull/piped input exits promptly; list/status/chip work')

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 120, 0, 0))
client_env = dict(os.environ, TERM='xterm-256color')
client_env.pop('TMUX', None)
client = subprocess.Popen(['tmux', '-L', sock, 'attach-session', '-t', 'work'],
                          stdin=slave, stdout=slave, stderr=slave, env=client_env)
os.close(slave)
output = b''


def until(predicate, seconds=5):
    global output
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            output += os.read(master, 65536)
    raise AssertionError(output.decode(errors='replace'))


def status_written(marker):
    try:
        with open(marker, encoding='utf-8') as status:
            return bool(status.read().strip())
    except FileNotFoundError:
        return False


def tmux(*args):
    return subprocess.check_output(['tmux', '-L', sock, *args], text=True, timeout=5)


try:
    until(lambda: bool(tmux('list-clients', '-F', '#{client_name}').strip()))
    client_name = tmux('list-clients', '-F', '#{client_name}').strip()
    # Install the actual prefix+a binding only; avoid unrelated daemon hooks.
    with open(here + '/tmux/tmux-agents.conf', encoding='utf-8') as config:
        binding = next(line for line in config if line.startswith('bind a '))
    marker = tmp + '/exit-status'
    wrapper = tmp + '/popup-command'
    with open(wrapper, 'w', encoding='utf-8') as script:
        script.write('#!/bin/sh\n' + shlex.quote(command[0]) + ' "$@"\n'
                     'result=$?\nprintf "%s" "$result" >' + shlex.quote(marker)
                     + '\nexit "$result"\n')
    os.chmod(wrapper, 0o755)
    binding = binding.replace('$TMUX_AGENTS_BIN/tmux-agents', wrapper)
    binding_file = tmp + '/binding.conf'
    with open(binding_file, 'w', encoding='utf-8') as config:
        config.write(binding)
    tmux('set-environment', '-g', 'PATH', env['PATH'])
    tmux('source-file', binding_file)
    os.write(master, b'\x02a')
    until(lambda: b'Press any key to close.' in output)
    assert b'brew install fzf' in output, output
    assert b'apt install fzf' in output, output
    # Observe persistence after rendering, before supplying any key.
    deadline = time.monotonic() + 0.3
    while time.monotonic() < deadline:
        assert not os.path.exists(marker), 'popup exited before a key press'
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            output += os.read(master, 65536)
    os.write(master, b'x')
    until(lambda: status_written(marker))
    with open(marker, encoding='utf-8') as status:
        assert status.read().strip() == '1'
    os.unlink(marker)
    print('ok    actual prefix+a popup shows instructions, persists, closes on key')
    # Redirection with an attached controlling terminal must not wait either.
    for redirect in ('</dev/null', "<<EOF\ninput\nEOF\n"):
        marker = tmp + '/exit-status'
        script = ('PATH=' + shlex.quote(env['PATH']) + ' ' + shlex.quote(command[0])
                  + ' ' + redirect + '\nprintf "%s" "$?" >' + shlex.quote(marker))
        tmux('display-popup', '-c', client_name, '-E', script)
        until(lambda: status_written(marker))
        with open(marker, encoding='utf-8') as status:
            assert status.read() == '1'
        os.unlink(marker)
    print('ok    redirected popup input exits with status 1 without waiting')
finally:
    client.terminate()
    client.wait(timeout=5)
    os.close(master)
