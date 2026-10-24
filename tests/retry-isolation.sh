#!/usr/bin/env bash
# Deterministic retry-lock isolation across sockets and receivers, with no live locks.
# RETRY_ISOLATION_BIN may select an old/frozen bin directory for red/green checks.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-retry-isolation.XXXXXX")"
sock_a="tmux-retry-isolation-a-$$"
sock_b="tmux-retry-isolation-b-$$"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() {
  cleanup_test_server "$sock_a" || return
  cleanup_test_server "$sock_b" || return
  rm -rf "$tmp"
}
trap cleanup EXIT
python3 - "${RETRY_ISOLATION_BIN:-$here/bin}" "$tmp" "$sock_a" "$sock_b" <<'PY'
import hashlib
import os
import pathlib
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time

source, temporary, socket_a, socket_b = sys.argv[1:]
root = pathlib.Path(temporary)
queue = root / 'isolated-queue'
queue.mkdir()
bins = root / 'bin'
shutil.copytree(source, bins)
# Redirect BOTH queue and identity locks. Never open the user's global root.
for path in bins.iterdir():
    if path.is_file():
        raw = path.read_bytes()
        old = b'/tmp/tmux-agents-$(id -u)/queue'
        if old in raw:
            path.write_bytes(raw.replace(old, str(queue).encode()))
print('source ask sha256=' + hashlib.sha256((pathlib.Path(source)/'tmux-ask').read_bytes()).hexdigest(), flush=True)
tools = root / 'tools'
tools.mkdir()
hooks = root / 'hooks'
hooks.mkdir()
real_tmux = shutil.which('tmux')
real_perl = shutil.which('perl')
assert real_tmux and real_perl
# Observe the actual lock call. The holder pauses AFTER obtaining its lock.
# NB contenders report the failed flock before we release the holder; blocking
# contenders report their attempt, then must wait for the explicit release.
(hooks / 'RetryGate.pm').write_text(r'''
package RetryGate;
use strict;
use warnings;
use Fcntl qw(LOCK_NB);
our ($path) = grep { /\/\.retry\.lock$/ } @ARGV;
sub event {
    my ($kind,$flags)=@_;
    open my $f,'>>',$ENV{RETRY_EVENTS} or die $!;
    print $f join("\t",$ENV{RETRY_LABEL},$kind,$path,$flags // 0),"\n";
    close $f;
}
sub hooked_flock ($$) {
    my ($fh,$flags)=@_;
    return CORE::flock($fh,$flags) unless defined $path;
    event('attempt',$flags);
    my $ok=CORE::flock($fh,$flags);
    event($ok ? 'acquired' : 'busy',$flags);
    if ($ok && $ENV{RETRY_HOLD}) {
        open my $gate,'<',$ENV{RETRY_RELEASE} or die $!;
        my $release=<$gate>;
        die 'release gate closed' unless defined $release;
        close $gate;
    }
    return $ok;
}
BEGIN { *CORE::GLOBAL::flock = \&hooked_flock; }
1;
''')
(tools/'perl').write_text('#!/bin/sh\nexec ' + shlex.quote(real_perl) + ' -I' + shlex.quote(str(hooks)) + ' -MRetryGate "$@"\n')
# Capture the exact message buffer, without waiting for cat/PTY output timing.
(tools/'tmux').write_text('''#!/bin/sh
if [ "$1" = paste-buffer ]; then
  shift
  previous=""
  for argument in "$@"; do
    if [ "$previous" = -b ]; then
      "$RETRY_REAL_TMUX" show-buffer -b "$argument" >>"$RETRY_CAPTURE"
      break
    fi
    previous="$argument"
  done
  set -- paste-buffer "$@"
fi
exec "$RETRY_REAL_TMUX" "$@"
''')
for p in tools.iterdir():
    p.chmod(0o755)
runner = root/'run-retry'
runner.write_text('''#!/bin/sh
"$RETRY_BIN/tmux-ask" --retry --to "$1"
rc=$?
printf '%s\tdone\t%s\t0\n' "$RETRY_LABEL" "$rc" >"$RETRY_EVENTS"
exit "$rc"
''')
runner.chmod(0o755)
env = dict(os.environ, XDG_STATE_HOME=str(root/'state'), TMUX_ASK_IDLE_SECS='0',
           TMUX_ASK_ENTER_DELAY='0', TMUX_ASK_COPY_IDLE_SECS='0')
for key in ('TMUX', 'TMUX_PANE', 'TMUX_ASK_IDENTITY_LOCKED', 'PERL5OPT', 'PERL5LIB'):
    env.pop(key, None)

def tmux(sock, *args):
    return subprocess.check_output([real_tmux, '-L', sock, *args], env=env, text=True).strip()

sockets = {}
for sock in (socket_a, socket_b):
    tmux(sock, '-f', '/dev/null', 'new-session', '-d', '-s', 'work', '-c', str(root), 'cat')
    tmux(sock, 'has-session')
    path = tmux(sock, 'display-message', '-p', '#{socket_path}')
    assert path and not path.endswith('/default'), 'unsafe test socket'
    sockets[sock] = path
    tmux(sock, 'set', '-g', 'default-shell', '/bin/sh')
    tmux(sock, 'set', '-p', '-t', '%0', '@agent', 'main')
    tmux(sock, 'set', '-p', '-t', '%0', '@agent_id', 'a000000000001')
    for index, name in ((2, 'one'), (3, 'two')):
        pane = tmux(sock, 'new-window', '-d', '-t', 'work', '-P', '-F', '#{pane_id}', 'cat')
        assert pane == '%' + str(index-1)
        tmux(sock, 'set', '-p', '-t', pane, '@agent', name)
        tmux(sock, 'set', '-p', '-t', pane, '@agent_id', f'a{index:012x}')
    (queue/sock).mkdir()

failed = 0
checks = 0
processes = []
def check(label, condition):
    global failed, checks
    checks += 1
    failed += not bool(condition)
    print(('ok    ' if condition else 'FAIL  ') + label, flush=True)

def staged(sock, receiver, marker, epoch):
    pane = '%1' if receiver == 'one' else '%2'
    aid = 'a000000000002' if receiver == 'one' else 'a000000000003'
    body = queue/sock/f'{epoch}-000001-{pane[1:]}.undelivered'
    body.write_text('[notice from main to '+receiver+' via tmux-ask]\n'+marker+'\n[end of notice from main to '+receiver+']')
    body.with_suffix('.meta').write_text(f'from_id=a000000000001\nto_id={aid}\nfrom_name=main\nto_name={receiver}\nto_pane={pane}\nkind=notice\nqueued_at={epoch}\nrequest_id=\n')
    return body

def scenario(label, second_socket):
    phase = root/label
    phase.mkdir()
    event_path = phase/'events'
    release = phase/'release'
    os.mkfifo(event_path)
    os.mkfifo(release)
    event_fd = os.open(event_path, os.O_RDWR | os.O_NONBLOCK)
    buffered = bytearray()
    held = True
    logs = []
    first = staged(socket_a, 'one', label+'-holder-message', 1000000000)
    second_receiver = 'one' if second_socket != socket_a else 'two'
    second = staged(second_socket, second_receiver, label+'-contender-message', 1000000001)
    def start(who, sock, receiver, hold):
        runenv = dict(env, TMUX=sockets[sock]+',1,0', TMUX_PANE='%0',
                      PATH=str(tools)+':'+env['PATH'], RETRY_REAL_TMUX=real_tmux,
                      RETRY_BIN=str(bins), RETRY_LABEL=who, RETRY_HOLD='1' if hold else '',
                      RETRY_EVENTS=str(event_path), RETRY_RELEASE=str(release),
                      RETRY_CAPTURE=str(phase/(who+'.capture')))
        log = open(phase/(who+'.log'), 'w')
        logs.append(log)
        p = subprocess.Popen([str(runner), receiver], env=runenv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(p)
        return p
    def event():
        deadline = time.monotonic()+30
        while b'\n' not in buffered:
            remaining = deadline-time.monotonic()
            if remaining <= 0 or not select.select([event_fd], [], [], remaining)[0]:
                raise RuntimeError(label+' timed out waiting for an explicit lock/process event')
            buffered.extend(os.read(event_fd, 65536))
        line, _, rest = buffered.partition(b'\n')
        buffered[:] = rest
        fields = line.decode().split('\t')
        print('event '+label+' '+line.decode(), flush=True)
        return fields
    def unlock():
        nonlocal held
        if held:
            with open(release, 'w') as f:
                f.write('release\n')
            held = False
    try:
        holder = start('holder', socket_a, 'one', True)
        while True:
            e = event()
            if e[0:2] == ['holder','acquired']:
                holder_path = e[2]
                break
            if e[1] == 'done':
                raise RuntimeError('holder exited before acquiring retry lock')
        contender = start('contender', second_socket, second_receiver, False)
        while True:
            e = event()
            if e[0:2] == ['contender','attempt']:
                contender_path, flags = e[2], int(e[3])
                break
            if e[1] == 'done':
                raise RuntimeError('contender exited before attempting retry lock')
        # macOS/Linux LOCK_NB is 4; retrieve it through Python's fcntl constant.
        import fcntl
        blocking = not (flags & fcntl.LOCK_NB)
        if second_socket != socket_a:
            separate = holder_path != contender_path
            check('cross socket uses distinct retry locks', separate)
            if not separate and blocking:
                check('cross socket contender can finish while holder stays locked', False)
                unlock()
            else:
                while True:
                    e = event()
                    if e[0:2] == ['contender','done']:
                        break
                capture = phase/'contender.capture'
                check('cross socket contender can finish while holder stays locked',
                      e[2] == '0' and not second.exists() and capture.exists()
                      and label+'-contender-message' in capture.read_text())
                unlock()
        else:
            check('same socket shares its retry lock', holder_path == contender_path)
            check('same socket competing retry blocks instead of dropping work', blocking)
            if blocking:
                unlock()
            else:
                # Observe the failed nonblocking flock and the CLI success exit
                # while the holder still owns the lock. Only then release it.
                busy = False
                while True:
                    e = event()
                    busy |= e[0:2] == ['contender','busy']
                    if e[0:2] == ['contender','done']:
                        break
                check('busy retry cannot return success with exact source undelivered',
                      not (busy and e[2] == '0' and second.exists()))
                unlock()
        rc1 = holder.wait(timeout=30)
        rc2 = contender.wait(timeout=30)
        check(label+' holder completed retry', rc1 == 0 and not first.exists())
        capture = phase/'contender.capture'
        check(label+' contender delivered its exact identity',
              rc2 == 0 and not second.exists() and capture.exists()
              and label+'-contender-message' in capture.read_text())
        check(label+' contender consumed matching metadata', not second.with_suffix('.meta').exists())
    finally:
        if held:
            # Never block cleanup opening a gate if its holder already died.
            if 'holder' in locals() and holder.poll() is None:
                os.killpg(holder.pid, signal.SIGTERM)
        for log in logs:
            log.close()
        os.close(event_fd)
        for path in phase.glob('*.log'):
            print(path.name+': '+path.read_text().strip(), flush=True)

try:
    scenario('cross', socket_b)
    scenario('same', socket_a)
finally:
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
print(f'{checks-failed}/{checks} passed', flush=True)
sys.exit(1 if failed else 0)
PY
