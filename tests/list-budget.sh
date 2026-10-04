#!/usr/bin/env bash
# Process-budget regression; optional --before SCRIPT compares identical snapshots.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
before=""
if [ "${1:-}" = --before ]; then before="$2"; shift 2; fi
[ "$#" -eq 0 ] || { echo 'usage: list-budget.sh [--before SCRIPT]' >&2; exit 1; }
sock="tmux-list-budget-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-list-budget.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/project-one" "$tmp/project-two" "$tmp/plain"
git init -q "$tmp/project-one"
git init -q "$tmp/project-two"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project-one" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
now="$(date +%s)"
tmux set -p -t %0 @agent main
for ((i=1; i<=49; i++)); do
  case "$((i%3))" in 0) dir="$tmp/project-one" ;; 1) dir="$tmp/project-two" ;; 2) dir="$tmp/plain" ;; esac
  p="$(tmux new-window -d -t work -c "$dir" -P -F '#{pane_id}' cat)"
  tmux set -p -t "$p" @agent "agent-$i"
  if [ "$i" -ne 25 ]; then
    parent=%0; [ "$i" -le 1 ] || parent="%$((i-1))"
    tmux set -p -t "$p" @parent "$parent"
  fi
  case "$((i%6))" in
    0) tmux set -p -t "$p" @state needs_you; tmux set -p -t "$p" @attention_since "$((now-i*10))" ;;
    1) tmux set -p -t "$p" @msg_waiting_since "$((now-i*10))" ;;
    2) tmux set -p -t "$p" @state idle ;;
  esac
done
records="$XDG_STATE_HOME/tmux-agents/${S##*/}/sessions"
mkdir -p "$records"
for ((i=1; i<=100; i++)); do
  case "$((i%3))" in 0) dir="$tmp/project-one" ;; 1) dir="$tmp/project-two" ;; 2) dir="$tmp/plain" ;; esac
  parent=main; [ "$i" -le 50 ] || parent="closed-$((i-50))"
  printf 'kind=codex\nid=bench-%s\ndir=%s\nparent=%s\nclosed=%s\n' "$i" "$dir" "$parent" "$((now-i))" >"$records/closed-$i"
done
. "$here/bin/lib.sh"
ensure_agent_ids "$tmp/queue"
# A control client establishes a real --client window, without a user server.
mkfifo "$tmp/input"
exec 9<>"$tmp/input"
tmux -C attach-session -t work:0 <"$tmp/input" >"$tmp/client.log" 2>&1 &
client=""
for i in {1..50}; do
  client="$(tmux list-clients -F '#{client_name}' | head -1)"
  [ -z "$client" ] || break
  sleep 0.1
done
[ -n "$client" ] || { echo 'FAIL no test client'; exit 1; }
mkdir "$tmp/ui"
cat >"$tmp/ui/fzf" <<'STUB'
#!/bin/bash
set -eu
: >"$BENCH_EXECUTED"
while IFS= read -r call; do printf '%s\n' "$call"; done <"$BENCH_CALLS" >"$BENCH_EXEC_CALLS"
reload=""
for arg in "$@"; do
  case "$arg" in
    --prompt=*) export FZF_PROMPT="${arg#--prompt=}" ;;
    start:reload\(*) reload="${arg#start:reload(}"; reload="${reload%)}" ;;
  esac
done
if [ -n "$reload" ]; then exec < <(eval "$reload"); fi
# Consume the initial batch and record its arrival before exiting; time measures
# receipt of the first batch, without Python startup noise.
found=0
while IFS= read -r -d '' row; do
  case "$row" in *NAME*) found=1 ;; esac
done
[ "$found" = 1 ]
if [ -n "${BENCH_SELECT:-}" ]; then
  case "$*" in *'load:pos('*|*'load:transform:'*) ;; *) exit 2 ;; esac
fi
printf 'ready' >"$BENCH_RECEIVED"
exit 1
STUB
chmod +x "$tmp/ui/fzf"
# Count tool launches in the production path. Shell builtins do not count.
# Shims exec the real binaries and never intercept socket selection/cleanup.
mkdir "$tmp/count"
export BENCH_CALLS="$tmp/calls" BENCH_NOW="$now"
for tool in tmux perl awk git basename sed date stat dirname tr column sort cut cat rm head wc mktemp fzf; do
  if [ "$tool" = fzf ]; then real="$tmp/ui/fzf"; else real="$(command -v "$tool")"; fi
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "%s" >>"$BENCH_CALLS"\n' "$tool"
    if [ "$tool" = tmux ]; then
      printf 'if [ "${1:-} ${2:-}" = "list-panes -a" ]; then printf "snapshot\\n" >>"$BENCH_CALLS"; fi\n'
    fi
    if [ "$tool" = date ]; then
      printf 'if [ "$*" = +%%s ]; then printf "%%s\\n" "$BENCH_NOW"; exit; fi\n'
    fi
    printf 'exec %q "$@"\n' "$real"
  } >"$tmp/count/$tool"
  chmod +x "$tmp/count/$tool"
done
export PATH="$tmp/count:$PATH" BENCH_RECEIVED="$tmp/received" BENCH_EXECUTED="$tmp/executed" BENCH_EXEC_CALLS="$tmp/exec-calls"
mkdir "$tmp/installed"
for file in "$here"/bin/tmux-* "$here/bin/lib.sh"; do ln -s "$file" "$tmp/installed/${file##*/}"; done
python3 - "$before" "$tmp/installed/tmux-agents" "$client" <<'PY'
import collections, os, statistics, subprocess, sys, time
before, after, client = sys.argv[1:]
print('fixture: 50 panes, 100 records, nested/closed ancestors, 3 paths', flush=True)
# 300ms was noisy under concurrent test load; process limits are deterministic.
# Keep a loose 1s regression cap, overridable on reliably faster/slower hosts.
cap = float(os.environ.get('TMUX_LIST_BUDGET_MS', '1000'))
print(f'budget: <=20 external tools per build; <={cap:g}ms median of 3 after runs', flush=True)
print(f'pre-fzf budget: <=3 tools and <={cap:g}ms per open', flush=True)
old = {}
checks = 0
for label, script in [('before', before), ('after', after)]:
    if not script:
        continue
    for mode in ('local', 'all', 'open', 'open-select'):
        env = dict(os.environ, TMUX_AGENTS_LIST_CLIENT=client)
        env['FZF_PROMPT'] = 'agents · ' + ('all windows> ' if mode == 'all' else 'this window> ')
        args = [script, '--list'] if mode in ('local','all') else [script, '--client', client]
        env['BENCH_SELECT'] = '1' if mode == 'open-select' else ''
        if mode == 'open-select': args += ['--select', 'agent-1']
        timings, counts, exec_times, exec_counts = [], [], [], []
        for repeat in range(3):
            open(env['BENCH_CALLS'], 'w').close()
            for key in ('BENCH_RECEIVED', 'BENCH_EXECUTED', 'BENCH_EXEC_CALLS'):
                if os.path.exists(env[key]): os.unlink(env[key])
            start = time.time()
            result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            end = time.time()
            if result.returncode:
                raise RuntimeError(result.stderr.decode())
            if mode.startswith('open'):
                with open(env['BENCH_RECEIVED']) as f: assert f.read() == 'ready'
                end = os.stat(env['BENCH_RECEIVED']).st_mtime_ns / 1e9
                exec_times.append((os.stat(env['BENCH_EXECUTED']).st_mtime_ns / 1e9 - start)*1000)
                exec_counts.append(sum(c != 'snapshot' for c in open(env['BENCH_EXEC_CALLS']).read().splitlines()))
            else:
                assert b'message waiting' in result.stdout and b'closed-100' in result.stdout
                if label == 'before': old[mode] = result.stdout
                elif mode in old:
                    assert result.stdout == old[mode], f'{mode}: output changed'
            calls = open(env['BENCH_CALLS']).read().splitlines()
            detail = collections.Counter(line for line in calls if line != 'snapshot')
            snapshots = calls.count('snapshot')
            calls = [line for line in calls if line != 'snapshot']
            timings.append((end-start)*1000)
            counts.append(len(calls))
            if label == 'after':
                if mode.startswith('open'):
                    assert exec_counts[-1] <= 3, (mode, exec_counts)
                    assert exec_times[-1] <= cap, (mode, exec_times)
                    checks += 2
                assert len(calls) <= 20, (mode, len(calls), detail)
                assert snapshots == 1, calls
                assert detail['git'] == 3, detail
                checks += 3
        if exec_times:
            print(f'{label:6s} {mode:11s} to fzf exec: {statistics.median(exec_times):.1f} ms; {max(exec_counts)} tools', flush=True)
        median = statistics.median(timings)
        print(f'{label:6s} {mode:11s} {median:8.1f} ms; {max(counts)} tools; {dict(detail)}', flush=True)
        if label == 'after':
            assert median <= cap, (mode, timings)
            checks += 1
print(f'{checks} budget/snapshot/cache checks passed', flush=True)
PY
