#!/usr/bin/env bash
# Watch terminal policy, spinner repaint, overflow, failure recovery and exit.
# Stub tmux and renderer isolate the shell/renderer environment contract.
set -euo pipefail
here="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-board-watch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$here/bin/tmux-agents-board" "$here/bin/lib.sh" "$here/bin/turn-state.sh" "$tmp/bin/"
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = show-options ]; then
  printf '@tmux_agents_chip_fps %s\n' "${TEST_FPS:-10}"
  exit 0
fi
printf 'Unexpected tmux call: %s\n' "$*" >&2
exit 1
STUB
cat > "$tmp/bin/tmux-agents-board.pl" <<'RENDER'
use strict;
use warnings;
if ($ENV{TEST_FAIL} && -f $ENV{TEST_FAIL}) {
    unlink $ENV{TEST_FAIL};
    die "fixture refresh failed\n";
}
my $color = $ENV{BOARD_COLOR} eq '1';
my $glyph = $color && $ENV{BOARD_SPIN} eq '1' ? "\001" : '⠿';
$glyph = '○' if $ENV{TEST_IDLE};
print "Mission board\n";
print(($color ? "\033[38;5;117m" : ''), "$glyph worker", ($color ? "\033[0m" : ''), "\n");
print "last row\n";
if ($ENV{TEST_TOGGLE}) {
    print $ENV{BOARD_ALL} eq '1' ? "M1 Earlier mission\n  ✓ Shipped earlier mission\n" : "… 1 earlier done: M1\n";
}
RENDER
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_PREFIX=agents
python3 - "$tmp/bin/tmux-agents-board" "$tmp" <<'PY'
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path

board, temp = sys.argv[1:]
base = dict(os.environ)
base.pop('NO_COLOR', None)
# Caller-supplied renderer flags cannot force escape codes into a pipe.
result = subprocess.run([board], env=dict(base, BOARD_COLOR='1', BOARD_SPIN='1'), capture_output=True)
assert result.returncode == 0 and b'\x1b' not in result.stdout, result
assert '⠿'.encode() in result.stdout, result.stdout
assert b'a all missions' not in result.stdout, result.stdout
help_text = subprocess.check_output([board, '--help'])
assert b'a toggles all missions' in help_text and b'q or Ctrl-C' in help_text, help_text


def run(height=12, watch=True, extra=None, animate=False, quit_signal=False, toggle=False, all_missions=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, 100, 0, 0))
    original_terminal = termios.tcgetattr(slave)
    # Give stty /dev/tty the actual PTY, as in a user's terminal.
    def terminal():
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    env = dict(base, **(extra or {}))
    if toggle:
        env['TEST_TOGGLE'] = '1'
    process = subprocess.Popen([board] + (['--watch', '30' if toggle else '1'] if watch else []) + (['--all'] if all_missions else []),
                               stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                               env=env, preexec_fn=terminal)
    os.close(slave)
    data = b''
    def collect(ready):
        nonlocal data
        deadline = time.monotonic() + 6
        while not ready(data) and time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                data += chunk
        assert ready(data), data
    try:
        if toggle:
            collect(lambda d: b'\x1b[J' in d)
            expanded = all_missions
            def check_view(chunk):
                assert (b'M1 Earlier mission' in chunk) == expanded, chunk
                assert ('✓ Shipped earlier mission'.encode() in chunk) == expanded, chunk
                assert (b'earlier done: M1' in chunk) != expanded, chunk
                assert 'a all missions · q quit'.encode() in chunk, chunk
            check_view(data)
            for _ in range(2):
                start = len(data)
                os.write(master, b'a')
                # Six-second failure deadline is below the 30-second refresh interval.
                collect(lambda d: b'\x1b[H\x1b[2J\x1b[3J' in d[start:] and b'\x1b[J' in d[start:])
                expanded = not expanded
                check_view(data[start:].split(b'\x1b[H\x1b[2J\x1b[3J')[-1])
        if watch and not toggle:
            collect(lambda d: d.count(b'\x1b[J') >= (3 if env.get('TEST_FAIL') else 2))
            # Examine a complete data-refresh interval, excluding refresh clears.
            interval = data.split(b'\x1b[H\x1b[2J\x1b[3J')[1].split(b'\x1b[J', 1)[1]
            if animate:
                assert b'\x1b[H' in interval and b'\x1b[2J' not in interval, interval
                glyphs = {g for g in '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' if g.encode() in data}
                assert len(glyphs) >= 2, data
            else:
                assert b'\x1b[H' not in interval, interval
            assert b'\x01' not in data, data
            if env.get('TEST_FAIL'):
                assert b'board: refresh failed (retrying)' in data and b'last row' in data, data
        if watch:
            assert b'a all missions' in data, data
            if quit_signal:
                process.send_signal(signal.SIGINT)
            else:
                os.write(master, b'q')
            collect(lambda d: b'\x1b[?25h' in d)
            restored = termios.tcgetattr(master)
            # macOS sets PENDIN when restoring canonical input; it is transient
            # kernel retyping state, not a changed user terminal setting.
            restored[3] &= ~getattr(termios, 'PENDIN', 0)
            original_terminal[3] &= ~getattr(termios, 'PENDIN', 0)
            assert restored == original_terminal, ("terminal not restored", original_terminal, restored)
        else:
            collect(lambda d: b'last row' in d)
            assert b'a all missions' not in data, data
    finally:
        os.close(master)
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise
    assert code == (130 if quit_signal else 0), (code, data, process.stderr.read())
    assert process.stderr.read() == b'', data
    if env.get('NO_COLOR'):
        assert re.search(rb'\x1b\[[0-9;]*m', data) is None, data
    return data

assert b'\x1b[' in run(watch=False)
run(watch=False, extra={'NO_COLOR': '1'})
run(animate=True)
run(animate=True, extra={'NO_COLOR': '', 'TEST_FPS': 'invalid'})
run(animate=True, extra={'TEST_FPS': '999999999999999999999999'})
run(height=2)  # Taller than the pane: no cursor-home animation or lost scrollback.
run(height=3)
run(height=4)  # The key footer counts towards overflow and prevents tick scrolling.
run(extra={'NO_COLOR': '1'})
run(extra={'TEST_IDLE': '1'})
run(extra={'TEST_FPS': '0'}, quit_signal=True)  # Clamped to one frame per second.
failure = Path(temp) / 'fail-once'
failure.touch()
run(extra={'TEST_FAIL': str(failure)})
run(toggle=True)
run(toggle=True, all_missions=True)
run(toggle=True, extra={'NO_COLOR': '1'})
run(toggle=True, extra={'TEST_IDLE': '1'})
print('PASS: board watch keys, immediate toggles, colour, animation, overflow, refresh recovery and exits')
PY
