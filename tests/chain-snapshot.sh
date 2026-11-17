#!/usr/bin/env bash
# Chain role choices and args stay fixed across launches and helper spawns.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-chain-snapshot-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-chain-snapshot.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/args"
for kind in claude codex other-agent; do
  cat >"$tmp/bin/$kind" <<'STUB'
#!/bin/sh
set -eu
printf '%s' "${CODEX_HOME:-}" >"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.home"
printf '%s\0' "$@" >"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.args"
env | sort >"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.env"
printf 'SPAWN STUB READY %s\n' "${0##*/}"
exec cat >>"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.input"
STUB
  chmod +x "$tmp/bin/$kind"
done
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
unset TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" SPAWN_ARGS_LOG="$tmp/args"
export TMUX_AGENTS_SUB_EXIT=keep TMUX_ASK_ENTER_DELAY=0
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 60 -c "$tmp/project" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: private test server did not start'; exit 1; }
socket_path="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$socket_path" in ''|*/default) echo "ABORT: unsafe test socket '$socket_path'"; exit 1 ;; esac
export TMUX="$socket_path,1,0" TMUX_PANE=%0
tmux set-option -g default-shell /bin/sh
tmux set-environment -g SPAWN_ARGS_LOG "$SPAWN_ARGS_LOG"
tmux set-option -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids

fail=0 count=0
check() {
  local label="$1"; shift
  count=$((count + 1))
  if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi
}
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
# Invoked indirectly by tests.
# shellcheck disable=SC2329
ready() {
  local pane="$1" i
  for ((i=0; i<100; i++)); do
    tmux capture-pane -p -J -t "$pane" -S -100 >"$tmp/screen"
    if grep -q 'SPAWN STUB READY' "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  return 1
}
# Invoked indirectly by check().
# shellcheck disable=SC2329
wait_ready() {
  local pane="$1"
  ready "$pane"
}
args_file() { printf '%s/%s.args\n' "$SPAWN_ARGS_LOG" "${1#%}"; }
# Invoked indirectly by check().
# shellcheck disable=SC2329
suffix_is() {
  local pane="$1"; shift
  python3 - "$(args_file "$pane")" "$@" <<'PY'
import pathlib, sys
actual = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
expected = [value.encode() for value in sys.argv[2:]]
assert actual[-len(expected):] == expected, (actual, expected)
PY
}
# Invoked indirectly by check().
# shellcheck disable=SC2329
recorded_args_are() {
  local id="$1"; shift
  python3 - "$(record_get "$id" cli_args)" "$@" <<'PY'
import base64, sys
actual = base64.b64decode(sys.argv[1]).split(b"\0")[:-1]
expected = [value.encode() for value in sys.argv[2:]]
assert actual == expected, (actual, expected)
PY
}
# Invoked indirectly by check().
# shellcheck disable=SC2329
no_model() { ! grep -Fq -- '--model' "$(args_file "$1")"; }
# Invoked indirectly by check().
# shellcheck disable=SC2329
rejects_with() {
  local expected="$1"; shift
  if "$B/tmux-spawn" --from main "$@" </dev/null >"$tmp/error" 2>&1; then return 1; fi
  grep -Fq -- "$expected" "$tmp/error"
}
role_spawn() {
  "$B/tmux-spawn" --from main "$@" </dev/null >"$tmp/spawn"
}


# Start with every additional launch flag and snapshot all seven roles.
for role in main designer interface worker reviewer runner researcher; do
  tmux set-option -g "@tmux_agents_chain_${role}_args" "--model snapshot-$role"
done
chain="$("$B/tmux-agents" start chain "$tmp/project" --target work --main codex --designer codex --interface claude --worker codex --reviewer codex --runner claude --researcher codex)"
check 'chain main stub starts' wait_ready "$chain"
check 'chain main role recorded' test "$(tmux show-options -pqv -t "$chain" @role)" = main
for role in MAIN DESIGNER SECONDARY WORKER REVIEWER RUNNER RESEARCHER; do
  case "$role" in SECONDARY|RUNNER) expected=claude ;; *) expected=codex ;; esac
  check "$role agent snapshot" grep -Fxq "TMUX_AGENTS_CHAIN_$role=$expected" "$SPAWN_ARGS_LOG/${chain#%}.env"
done
for role in main designer interface worker reviewer runner researcher; do
  chain_role_env "$role" env_key
  check "$role args snapshot" grep -Fxq "${env_key}_ARGS=--model snapshot-$role" "$SPAWN_ARGS_LOG/${chain#%}.env"
done
# A helper receives the original snapshot even after live settings change.
while IFS= read -r entry; do
  case "$entry" in TMUX_AGENTS_CHAIN_*=*) export "${entry?}" ;; esac
done <"$SPAWN_ARGS_LOG/${chain#%}.env"
tmux set-option -g @tmux_agents_chain_reviewer claude
tmux set-option -g @tmux_agents_chain_reviewer_args '--model changed'
role_spawn --role reviewer --name retained
retained="$(pane_of codex-project-retained)"
check 'helper follows launch snapshot' wait_ready "$retained"
check 'helper retains launch args' suffix_is "$retained" --model snapshot-reviewer
check 'helper resolution reports chain' grep -Fxq 'role=reviewer agent=codex args="--model snapshot-reviewer" source=chain' "$tmp/spawn"
python3 - "$(args_file "$retained")" <<'CHECK'
import json, pathlib, sys
args=pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')[:-1]
pins={}
for arg in args:
    if arg.startswith(b'shell_environment_policy.set.'):
        key,value=arg.decode().split('=',1)
        pins[key.removeprefix('shell_environment_policy.set.')]=json.loads(value)
for role in ['MAIN','DESIGNER','SECONDARY','WORKER','REVIEWER','RUNNER','RESEARCHER']:
    assert 'TMUX_AGENTS_CHAIN_'+role in pins, (role,pins)
    assert 'TMUX_AGENTS_CHAIN_'+role+'_ARGS' in pins, (role,pins)
assert pins['TMUX_AGENTS_CHAIN_REVIEWER_ARGS']=='--model snapshot-reviewer', pins
CHECK
check 'Codex pins every role and args' test "$?" = 0

# Returned shells restore presence and literal values for all added env keys.
export TMUX_AGENTS_CHAIN_DESIGNER_ARGS=''
unset TMUX_AGENTS_CHAIN_RESEARCHER_ARGS
launch_env_snapshot
export TMUX_AGENTS_CHAIN_DESIGNER_ARGS=changed TMUX_AGENTS_CHAIN_RESEARCHER_ARGS=changed
launch_env_restore
check 'empty original args restored' test "${TMUX_AGENTS_CHAIN_DESIGNER_ARGS+x}:${TMUX_AGENTS_CHAIN_DESIGNER_ARGS}" = x:
check 'absent original args restored' test -z "${TMUX_AGENTS_CHAIN_RESEARCHER_ARGS+x}"
[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
