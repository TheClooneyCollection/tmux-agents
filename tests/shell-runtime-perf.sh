#!/usr/bin/env bash
# Measure plain-shell opening against a copied git baseline on a private socket.
# Optional SHELL_PERF_BASE chooses the pre-change ref (default 4ca5879).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-agents-shell-perf-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-shell-perf.XXXXXX")"
real_tmux="$(command -v tmux)"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
mkdir -p "$tmp/wrappers" "$tmp/baseline/bin" "$tmp/project"
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/wrappers"
for agent in claude codex; do
  printf '#!/bin/sh\necho "FAKE %s"\nexec cat\n' "$agent" >"$tmp/wrappers/$agent"
  chmod +x "$tmp/wrappers/$agent"
  "$tmp/wrappers/$agent" </dev/null | grep -qx "FAKE $agent"
done
# Copy only the required baseline code, never modify the source checkout.
if git -C "$here" cat-file -e "${SHELL_PERF_BASE:-4ca5879}:bin/tmux-shell" 2>/dev/null; then
  git -C "$here" show "${SHELL_PERF_BASE:-4ca5879}:bin/tmux-shell" >"$tmp/baseline/bin/tmux-shell"
  git -C "$here" show "${SHELL_PERF_BASE:-4ca5879}:bin/lib.sh" >"$tmp/baseline/bin/lib.sh"
  chmod +x "$tmp/baseline/bin/tmux-shell"
else
  echo 'Baseline unavailable in this checkout; checking current runtime budget only.'
fi
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
cat >"$tmp/wrappers/tmux" <<'STUB'
#!/bin/sh
if [ -n "${PERF_LOG:-}" ]; then
  perl -MTime::HiRes=time -e 'open my $f, ">>", $ARGV[0] or die $!; print $f time(), "\n"' "$PERF_LOG"
fi
if [ "$1" = run-shell ] && [ "$2" = -b ]; then
  case "$3" in *display-popup*)
    perl -MTime::HiRes=time -e 'open my $f, ">", $ARGV[0] or die $!; print $f time()' "$PERF_POPUP"
    exit 0 ;;
    *) exit 0 ;; # Deferred labels are outside the startup critical path.
  esac
fi
exec "$PERF_TMUX" "$@"
STUB
cat >"$tmp/wrappers/marker-shell" <<'STUB'
#!/bin/sh
if [ "$1" = -l ]; then
  perl -MTime::HiRes=time -e 'open my $f, ">", $ARGV[0] or die $!; print $f time()' "$PERF_MARKER"
fi
exec /bin/sh "$@"
STUB
chmod +x "$tmp/wrappers/tmux" "$tmp/wrappers/marker-shell"
export PERF_TMUX="$real_tmux" PATH="$tmp/wrappers:$PATH"
# tmux-created processes receive these values through the private server.
export PERF_MARKER="$tmp/marker" PERF_POPUP="$tmp/popup"
tmux set-environment -g PERF_TMUX "$real_tmux"
tmux set-environment -g PERF_MARKER "$PERF_MARKER"
tmux set -g default-shell "$tmp/wrappers/marker-shell"
python3 - "$tmp" "$here" <<'PY'
import os, pathlib, statistics, subprocess, sys, time
root, repo = map(pathlib.Path, sys.argv[1:])
scripts = [('after', repo/'bin/tmux-shell')]
if (root/'baseline/bin/tmux-shell').exists():
    scripts.insert(0, ('before', root/'baseline/bin/tmux-shell'))
for instrument in (True, False):
    for label, script in scripts:
        rows = []
        for iteration in range(5):
            marker, popup, log = root/'marker', root/'popup', root/'calls'
            for path in (marker, popup, log):
                path.unlink(missing_ok=True)
            env = dict(os.environ, PERF_LOG=str(log) if instrument else '')
            subprocess.run([os.environ['PERF_TMUX'], 'set-environment', '-g', 'PERF_LOG', env['PERF_LOG']], check=True)
            start = time.time()
            subprocess.run([str(script), '--pane', '%0', '--client', 'test-client'], env=env, check=True, stdout=subprocess.DEVNULL)
            deadline = time.monotonic()+10
            while not (marker.exists() and popup.exists()):
                if time.monotonic() > deadline:
                    raise RuntimeError('shell or popup marker missing')
                time.sleep(.005)
            shell_time, popup_time = float(marker.read_text()), float(popup.read_text())
            calls = [float(x) for x in log.read_text().splitlines()] if instrument else []
            rows.append((sum(x <= shell_time for x in calls), (shell_time-start)*1000, (popup_time-start)*1000, sum(x <= popup_time for x in calls)))
            panes = subprocess.check_output([os.environ['PERF_TMUX'], 'list-panes', '-a', '-F', '#{pane_id} #{@shell}'], text=True)
            for line in panes.splitlines():
                fields = line.split()
                if fields[-1] == '1':
                    subprocess.run([os.environ['PERF_TMUX'], 'kill-pane', '-t', fields[0]], check=True)
        med = [statistics.median(row[i] for row in rows) for i in range(4)]
        print(f'{label} instrumented={instrument}: median calls-before-shell={med[0]:g} calls-before-popup={med[3]:g} shell={med[1]:.1f}ms popup={med[2]:.1f}ms (n=5; shell-call samples={[row[0] for row in rows]})', flush=True)
        if label == 'after' and instrument and med[0] > 12:
            raise RuntimeError('shell startup exceeded 12 tmux calls')
PY
