#!/usr/bin/env bash
# Launcher argv, shared hooks, profile pinning, lifecycle and chain, isolated.
# Commands and literal argv below intentionally contain unexpanded dollars.
# shellcheck disable=SC2016
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-launcher-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-launcher.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  cat > "$tmp/bin/$a" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\0' "$@" > "$TEST_LOG/$TMUX_PANE.args"
printf '%s\n' "${CODEX_HOME:-}" > "$TEST_LOG/$TMUX_PANE.home"
printf '%s\n' "${TMUX_AGENTS_NAME_FORMAT-unset}" > "$TEST_LOG/$TMUX_PANE.name-format"
printf '%s\n' "${TMUX_START_NAME_EXACT-unset}" > "$TEST_LOG/$TMUX_PANE.name-marker"
printf '%s\n' "${TMUX_START_CHAIN_WORK-unset}" > "$TEST_LOG/$TMUX_PANE.chain-marker"
tmux display -p -t "$TMUX_PANE" '#{@tracked} #{@agent_id} #{@started}' > "$TEST_LOG/$TMUX_PANE.init"
while IFS= read -r line; do [ "$line" != exit ] || exit 7; done
STUB
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
unset TMUX_AGENTS_NAME_FORMAT TMUX_START_NAME_EXACT TMUX_START_CHAIN_WORK
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TEST_LOG="$tmp"
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 70 -c "$tmp" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -g @tmux_agents_name_format prefixed
. "$B/lib.sh"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
wait_file() { local i; for ((i=0;i<100;i++)); do [ ! -s "$1" ] || return 0; sleep .05; done; return 1; }
info() { tmux display -p -t "$1" "#{@$2}"; }
# Current-pane invocation returns to its calling shell even on agent failure.
# The test server uses /bin/sh (dash on Linux), so Bash %q is not portable.
cmd="$(python3 - "$B/tmux-agents-start" <<'PYARGV'
import shlex, sys
print(shlex.join(['env', 'TMUX_AGENTS_NAME_FORMAT=exact', sys.argv[1],
                  'claude', '--name', 'exactness', '--', 'space here', '',
                  'quote" $value; *', 'line\nbreak']))
PYARGV
)"
new="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "$cmd; echo SHELL_RETURN; exec cat")"
wait_file "$tmp/$new.init"
check 'current pane preserves genuine user name-format environment' test "$(cat "$tmp/$new.name-format")" = exact
check 'current pane has no internal name marker' test "$(cat "$tmp/$new.name-marker")" = unset
check 'stub reports its marker' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE claude"' _ "$new"
check 'tracked, identity and work initialized before child' grep -Eq '^1 a[0-9a-f]{12} [0-9]+$' "$tmp/$new.init"
python3 - "$tmp/$new.args" <<'PY'
import sys,json
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[-4:]==[b'space here',b'',b'quote" $value; *',b'line\nbreak'],args
assert b'--permission-mode' not in args
hooks=json.loads(args[args.index(b'--settings')+1]); assert set(hooks['hooks'])=={'Notification','PostToolUse','UserPromptSubmit','Stop'}
PY
check 'Claude argv exactness, hooks and default permission mode' test "$?" = 0
check 'plain Claude with opaque arguments begins idle' test "$(info "$new" state)" = idle
check 'plain Claude has no active clock' test -z "$(info "$new" turn_start)"
check 'plain Claude starts with zero work' test "$(info "$new" worked)" = 0
printf '%s\n' '{"prompt":"[notice from parent to agent via tmux-ask] information"}' | "$B/tmux-agent-report" --pane "$new" --turn-start
check 'notice hook keeps idle launcher idle' test "$(info "$new" state)" = idle
check 'notice hook does not start clock' test -z "$(info "$new" turn_start)"
printf '%s\n' '{"prompt":"perform the task"}' | "$B/tmux-agent-report" --pane "$new" --turn-start
check 'real turn-start wakes idle launcher' test "$(info "$new" state)" = working
check 'real turn-start starts clock' test -n "$(info "$new" turn_start)"
aid="$(info "$new" agent_id)"
tmux set-option -p -t "$new" @turn_start 100
agent_save_work "$new" 105
add_peer %0 "$new"
add_peer "$new" %0
tmux set-option -p -t %0 @parent "$new"
tmux set-option -p -t "$new" @waiting_on background
tmux set-option -p -t "$new" @attention_since 1
tmux send-keys -t "$new" exit Enter
for ((i=0;i<100;i++)); do tmux capture-pane -p -t "$new" | grep -q SHELL_RETURN && break; sleep .05; done
check 'child exit clears identity' test -z "$(info "$new" agent_id)"
check 'child exit clears tracking' test -z "$(info "$new" tracked)"
check 'exit removes peer relationship' test -z "$(info %0 peers)"
check 'exit detaches children from reused shell pane' test -z "$(info %0 parent)"
check 'exit clears waiting and attention markers' test -z "$(info "$new" waiting_on)$(info "$new" attention_since)"
check 'record retains worked time' test "$(record_get "$aid" worked)" = 5
check 'record closed' test -n "$(record_get "$aid" closed)"
check 'record tagged top-level' test "$(record_get "$aid" launcher)" = 1
check 'top-level omitted from resumable subagents' bash -c '! "$1/tmux-spawn" --list-closed | grep -q "$2"' _ "$B" "$aid"
for ((i=0;i<100;i++)); do tmux capture-pane -p -t "$new" | grep -q SHELL_RETURN && break; sleep .05; done
check 'caller resumes after child exit' bash -c 'tmux capture-pane -p -t "$1" | grep -q SHELL_RETURN' _ "$new"
cmd="$(python3 - "$B/tmux-agents-start" <<'PYARGV'
import shlex, sys
print(shlex.join([sys.argv[1], 'extra', '--name', 'profile', '--',
                  '--resume', 'thread with spaces']))
PYARGV
)"
pane="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "$cmd; exec cat")"
wait_file "$tmp/$pane.init"
check 'current pane formats profile name' test "$(info "$pane" agent)" = "codex-${tmp##*/}-profile"
check 'profile preserves default name-format environment' test "$(cat "$tmp/$pane.name-format")" = unset
check 'profile has no internal name marker' test "$(cat "$tmp/$pane.name-marker")" = unset
check 'Codex stub marker' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE codex"' _ "$pane"
check 'plain profile with opaque arguments begins idle' test "$(info "$pane" state)" = idle
check 'plain profile has no active clock' test -z "$(info "$pane" turn_start)"
check 'profile has no internal chain marker' test "$(cat "$tmp/$pane.chain-marker")" = unset
check 'profile CODEX_HOME' test "$(cat "$tmp/$pane.home")" = "$tmp/profile"
check 'profile independent parent' test -z "$(info "$pane" parent)"
check 'profile independent peers' test -z "$(info "$pane" peers)"
python3 - "$tmp/$pane.args" "$pane" <<'PY'
import sys,json
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
notify=next(a for a in args if a.startswith(b'notify='))
notify=json.loads(notify.split(b'=',1)[1])
assert notify[1]=='--agent-id' and notify[-1]=='--codex-notify'
assert notify[2].startswith('a') and len(notify[2])==13
assert not any(b'approvals_reviewer' in a for a in args)
assert any(b'notify=[' in a for a in args)
assert ('shell_environment_policy.set.TMUX_PANE="'+sys.argv[2]+'"').encode() in args
assert b'shell_environment_policy.set.TMUX_AGENTS_KIND="extra"' in args
assert args[-2:]==[b'--resume',b'thread with spaces']
PY
check 'Codex pins, notify, passthrough and default approvals' test "$?" = 0
python3 - "$tmp/$pane.args" <<'PYTEST'
import json,subprocess,sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
notify=json.loads(next(a for a in args if a.startswith(b'notify=')).split(b'=',1)[1])
subprocess.run(notify+[json.dumps({'type':'agent-turn-complete','thread-id':'launcher-first-thread','input-messages':['plain user prompt'],'last-assistant-message':'Finished'})],check=True)
PYTEST
check 'notify before work leaves idle launcher idle' test "$(info "$pane" state)" = idle
check 'notify before work never charges idle time' test "$(info "$pane" worked)" = 0
check 'notify before work never starts clock' test -z "$(info "$pane" turn_start)"
check 'actual launcher notify saves conversation' test "$(record_get "$(info "$pane" agent_id)" id)" = launcher-first-thread
TMUX_PANE=%0 "$B/tmux-agents-start" chain "$tmp" --worker extra
chain="$(tmux display -p '#{pane_id}')"
wait_file "$tmp/$chain.init"
check 'chain does not force agent name-format environment' test "$(cat "$tmp/$chain.name-format")" = unset
check 'chain consumes internal name marker' test "$(cat "$tmp/$chain.name-marker")" = unset
check 'chain window basename' test "$(tmux display -p -t "$chain" '#{window_name}')" = "${tmp##*/}"
check 'chain initial prompt begins working' test "$(info "$chain" state)" = working
check 'chain initial prompt starts clock' test -n "$(info "$chain" turn_start)"
check 'chain consumes its internal work marker' test "$(cat "$tmp/$chain.chain-marker")" = unset
check 'chain starts Claude' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE claude"' _ "$chain"
python3 - "$tmp/$chain.args" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[-1]==b'start the chain; use extra as the worker'
PY
check 'chain initial prompt includes worker' test "$?" = 0
# Shared builder keeps spawn auto mode and resume semantics.
(
  here="$B"
  resolve_codex_homes codex_homes
  build_agent_command claude spawn session-test
  printf '%s\0' "${agent_command[@]}" > "$tmp/spawn-claude.args"
  build_agent_command codex spawn thread-test resume
  printf '%s\0' "${agent_command[@]}" > "$tmp/spawn-codex.args"
)
python3 - "$tmp" <<'PYTEST'
import sys
from pathlib import Path
root=Path(sys.argv[1])
a=(root/'spawn-claude.args').read_bytes().split(b'\0')[:-1]
b=(root/'spawn-codex.args').read_bytes().split(b'\0')[:-1]
assert a[:3]==[b'claude',b'--permission-mode',b'auto']
assert a[-2:]==[b'--session-id',b'session-test']
assert b[:2]==[b'codex',b'resume']
assert b'approvals_reviewer="auto_review"' in b and b[-1]==b'thread-test'
PYTEST
check 'shared builder preserves spawn auto and resume' test "$?" = 0
# Agent arguments after -- remain opaque, including removed launcher options.
cmd="$(python3 - "$B/tmux-agents-start" <<'PYARGV'
import shlex, sys
print(shlex.join(['env', 'TMUX_AGENTS_NAME_FORMAT=exact', sys.argv[1],
                  'codex', '--name', 'literal-label', '--',
                  "quote' and $d; *", '', 'two\nlines', '--split', 'below']))
PYARGV
)"
plain="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "$cmd; exec cat")"
wait_file "$tmp/$plain.init"
check 'plain Codex stub marker' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE codex"' _ "$plain"
check 'plain Codex retains caller exact name setting' test "$(info "$plain" agent)" = literal-label
check 'plain Codex with opaque arguments begins idle' test "$(info "$plain" state)" = idle
check 'plain Codex has no active clock' test -z "$(info "$plain" turn_start)"
python3 - "$tmp/$plain.args" <<'PYTEST'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[-5:]==[b"quote' and $d; *",b'',b'two\nlines',b'--split',b'below'],args[-5:]
PYTEST
check 'current-pane argv retains quotes empty newline and opaque --split' test "$?" = 0
before="$(tmux list-panes -a -F '#{pane_id}')"
before_identity="$(info %0 agent_id)"
if TMUX_PANE=%0 TMUX_AGENTS_NAME_FORMAT=exact "$B/tmux-agents-start" claude --name 'invalid name' >"$tmp/error" 2>&1; then
  echo 'FAIL invalid name accepted'; fail=1
fi
check 'invalid name allocates no pane' test "$(tmux list-panes -a -F '#{pane_id}')" = "$before"
check 'invalid name preserves pane identity' test "$(info %0 agent_id)" = "$before_identity"
check 'invalid name leaves no agent state' test -z "$(info %0 agent)$(info %0 tracked)"
for direction in right below; do
  if TMUX_PANE=%0 "$B/tmux-agents-start" codex --split "$direction" >"$tmp/error" 2>&1; then
    echo "FAIL --split $direction accepted"; fail=1
  fi
  check "--split $direction rejected as unknown launcher argument" grep -q "unknown launcher argument '--split'" "$tmp/error"
done
check 'rejected split allocates no pane' test "$(tmux list-panes -a -F '#{pane_id}')" = "$before"
check 'rejected split leaves no agent state' test -z "$(info %0 agent_id)$(info %0 agent)$(info %0 tracked)"
check 'launcher help omits --split' bash -c '! "$1/tmux-agents-start" --help | grep -q -- --split' _ "$B"
exit "$fail"
