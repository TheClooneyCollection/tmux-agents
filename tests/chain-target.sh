#!/usr/bin/env bash
# Chain target selection, stdout, validation and rename ordering, private socket.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-agents-chain-target-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-chain-target.XXXXXX")"
real_tmux="$(command -v tmux)"
mkdir -p "$tmp/bin" "$tmp/project's space"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
unset TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER
unset TMUX_AGENTS_NAME_FORMAT TMUX_START_NAME_EXACT TMUX_START_CHAIN_WORK
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TEST_LOG="$tmp"
export TEST_TMUX="$real_tmux" TEST_SOCKET="$sock"
# All commands, including children with TMUX unset, are confined to this socket.
cat > "$tmp/bin/tmux" <<'WRAPPER'
#!/bin/sh
exec "$TEST_TMUX" -L "$TEST_SOCKET" "$@"
WRAPPER
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH"
for agent in claude codex; do
  cat > "$tmp/bin/$agent" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'FAKE %s\n' "${0##*/}"
tmux show-options -w -v -t "$TMUX_PANE" automatic-rename > "$TEST_LOG/$TMUX_PANE.auto"
tmux show-options -w -v -t "$TMUX_PANE" allow-rename > "$TEST_LOG/$TMUX_PANE.allow"
printf '%s\0' "$@" > "$TEST_LOG/$TMUX_PANE.args"
printf '%s\n' "$PWD" > "$TEST_LOG/$TMUX_PANE.cwd"
printf '\033]2;chain-title-race\007\033kchain-rename-race\033\\'
printf 'FAKE READY\n'
exec cat
STUB
  chmod +x "$tmp/bin/$agent"
done
tmux -L "$sock" -f /dev/null new-session -d -s source -x 180 -y 50 -c "$tmp" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -g automatic-rename on
tmux set -g allow-rename on
tmux new-session -d -s destination -c "$tmp" cat
tmux new-window -d -t destination:2 -c "$tmp" cat
python3 - "$here" "$tmp" "$S" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import time

repo, tmp, socket = sys.argv[1:]
root = Path(tmp)
project = root / "project's space"
launcher = str(Path(repo) / 'bin/tmux-agents-start')
env = dict(os.environ, TMUX_PANE='%0')

def tmux(*args):
    return subprocess.check_output(['tmux', *args], text=True).strip()

def field(pane, name):
    return tmux('display', '-p', '-t', pane, '#{' + name + '}')

def windows():
    return tmux('list-windows', '-a', '-F', '#{session_id}:#{window_id}:#{window_index}')

def active(session):
    return tmux('list-windows', '-t', session, '-F', '#{window_id}:#{window_active}')

def selected(session):
    return next(line.split(':')[0] for line in active(session).splitlines() if line.endswith(':1'))

def ready(pane, kind):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        screen = tmux('capture-pane', '-p', '-t', pane)
        if ('FAKE ' + kind in screen and 'FAKE READY' in screen
                and field(pane, 'pane_title') == 'chain-title-race'):
            return
        time.sleep(.025)
    raise AssertionError(('stub not ready', pane, screen))

def launch(args, *, name, cwd=project, kind='claude', environment=env, target=None):
    source_before, dest_before = selected('source'), selected('destination')
    # /bin/bash is intentionally explicit: macOS ships Bash 3.2, whose nounset
    # semantics differ for the empty role-options array.
    result = subprocess.run(['/bin/bash', launcher, 'chain', *map(str, args)],
                            env=environment, cwd=cwd, capture_output=True)
    assert result.returncode == 0, (args, result.returncode, result.stderr)
    assert re.fullmatch(rb'%[0-9]+\n', result.stdout), (args, result.stdout)
    assert result.stderr == b'', (args, result.stderr)
    pane = result.stdout.decode().strip()
    ready(pane, kind)
    assert (root / (pane + '.auto')).read_text().strip() == 'off'
    assert (root / (pane + '.allow')).read_text().strip() == 'off'
    assert field(pane, 'window_name') == name, (pane, field(pane, 'window_name'), name)
    actual_cwd = (root / (pane + '.cwd')).read_text().strip()
    assert Path(actual_cwd).resolve() == Path(cwd).resolve(), (actual_cwd, str(cwd))
    assert field(pane, '@agent') != name, 'window name leaked into agent identity'
    assert field(pane, '@agent').startswith(kind + '-'), field(pane, '@agent')
    if target:
        assert field(pane, 'session_name') == target
        assert selected('source') == source_before
        assert selected('destination') == dest_before
    else:
        assert field(pane, 'session_name') == 'source'
        assert selected('source') == field(pane, 'window_id')
    print('ok   ', args or ['default chain'])
    return pane

# Chain help succeeds before it needs a caller pane or server connection.
for help_flag in ('--help', '-h'):
    help_env = dict(env, TMUX='/nonexistent/tmux-chain-help-socket,1,0')
    help_env.pop('TMUX_PANE', None)
    result = subprocess.run(['/bin/bash', launcher, 'chain', help_flag],
                            env=help_env, capture_output=True)
    assert result.returncode == 0, (help_flag, result.stderr)
    assert b'start chain' in result.stdout and result.stderr == b''
    print('ok    chain help', help_flag)

# No role flags exercises empty role-options under Bash 3.2.
launch([], name=project.name)
launch(['--name', "window's label", '--target', 'destination'],
       name="window's label", target='destination')
# The initial destination has 0 and 2 occupied; next free index is 1.
assert tmux('display', '-p', '-t', 'destination:1', '#{window_name}') == "window's label"
launch(['--target', 'destination:7', '--main', 'codex', project,
        '--name', 'explicit index', '--secondary', 'claude', '--worker', 'codex'],
       name='explicit index', kind='codex', target='destination')
assert tmux('display', '-p', '-t', 'destination:7', '#{window_name}') == 'explicit index'
# DIR also works after all role flags; --name is allowed without a target.
launch(['--worker', 'claude', '--main', 'claude', '--secondary', 'codex',
        '--name', 'focused custom', project], name='focused custom')
launch(['/'], name='root', cwd=Path('/'))
outside = dict(env)
outside.pop('TMUX', None)
outside.pop('TMUX_PANE', None)
launch(['--target', 'destination:8', project], name=project.name,
       environment=outside, target='destination')
# These calls must exercise TMUX itself, not the wrapper's forced -L.
# The unset-TMUX case above keeps its wrapper to avoid the user's server.
assert socket and Path(socket).name != 'default' and Path(socket).is_socket(), socket
real_path = os.pathsep.join(part for part in outside['PATH'].split(os.pathsep)
                            if part != str(root / 'bin'))
for socket_env in (socket, socket + ',1,0'):
    no_pane = dict(outside, TMUX=socket_env, PATH=real_path)
    launch(['--target', 'destination', project], name=project.name,
           environment=no_pane, target='destination')

# Every rejection must be diagnosed on stderr and leave all windows intact.
bad = [
    ['--target'], ['--target', ''], ['--target', '--name'],
    ['--name'], ['--name', ''], ['--name', '--target'],
    ['--target', 'no-such-session'], ['--target', 'destination:7'],
    ['--target', 'destination:nope'], ['--target', ':9'],
    [str(root / 'missing')], [project, project], ['--unknown'],
]
for role in ('main', 'secondary', 'worker'):
    bad += [['--target', 'destination', '--' + role, 'missing-agent-xyz'],
            ['--' + role], ['--' + role, '']]
for args in bad:
    before = windows()
    source_before, dest_before = selected('source'), selected('destination')
    result = subprocess.run(['/bin/bash', launcher, 'chain', *map(str, args)],
                            env=env, cwd=project, capture_output=True)
    assert result.returncode != 0, ('accepted invalid args', args)
    assert result.stdout == b'', (args, result.stdout)
    assert result.stderr.strip(), ('no diagnostic', args)
    assert windows() == before, ('created window on failure', args)
    assert selected('source') == source_before and selected('destination') == dest_before
    print('ok    rejects', args)
print('PASS: chain targets, names, stdout and rename ordering')
PY
