#!/usr/bin/env bash
# Role selection supplies agent, literal CLI args and names, preserved on resume.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-spawn-role-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-spawn-role.XXXXXX")"
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
spawn_agent() { local kind="$1"; shift; "$B/tmux-spawn" "$kind" --from main "$@"; }
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

role_spawn --role runner
runner="$(pane_of claude-project-runner)"
check 'runner starts Claude stub' wait_ready "$runner"
check 'runner default model reaches argv' suffix_is "$runner" --model haiku
runner_id="$(pane_agent_id "$runner")"
check 'runner effective args are saved' recorded_args_are "$runner_id" --model haiku
"$B/tmux-dismiss" --from main claude-project-runner >"$tmp/dismiss"
"$B/tmux-spawn" --from main --resume-id "$runner_id" </dev/null >"$tmp/resume"
runner="$(pane_of claude-project-runner)"
check 'role agent resumes' wait_ready "$runner"
check 'resume preserves role args' suffix_is "$runner" --model haiku

role_spawn --role reviewer
reviewer="$(pane_of claude-project-reviewer)"
check 'reviewer starts Claude stub' wait_ready "$reviewer"
check 'reviewer uses default model' no_model "$reviewer"
role_spawn --role secondary
interface="$(pane_of claude-project-interface)"
check 'secondary alias uses interface name' wait_ready "$interface"
check 'secondary alias uses interface args' suffix_is "$interface" --model sonnet

spawn_agent codex --role runner --name different </dev/null >"$tmp/spawn"
different="$(pane_of codex-project-different)"
check 'positional agent overrides role' wait_ready "$different"
check 'different positional agent drops role args' no_model "$different"
spawn_agent claude --role runner --name same </dev/null >"$tmp/spawn"
same="$(pane_of claude-project-same)"
check 'same positional agent starts' wait_ready "$same"
check 'same positional agent keeps role args' suffix_is "$same" --model haiku

role_spawn --role runner --name replaced -- --model x
replaced="$(pane_of claude-project-replaced)"
check 'explicit name overrides role name' wait_ready "$replaced"
check 'explicit CLI args replace role args' suffix_is "$replaced" --model x
check 'only replacement args are saved' recorded_args_are "$(pane_agent_id "$replaced")" --model x
role_spawn --role runner --name cleared --
cleared="$(pane_of claude-project-cleared)"
check 'bare separator starts agent' wait_ready "$cleared"
check 'bare separator clears role args' no_model "$cleared"
check 'empty effective args are saved' recorded_args_are "$(pane_agent_id "$cleared")"

tmux set-option -g @tmux_agents_chain_runner codex
role_spawn --role runner --name option-agent
option_agent="$(pane_of codex-project-option-agent)"
check 'role agent option selects Codex' wait_ready "$option_agent"
check 'overridden role agent drops default model' no_model "$option_agent"
tmux set-option -g @tmux_agents_chain_runner_args '--model option-model'
role_spawn --role runner --name option-args
option_args="$(pane_of codex-project-option-args)"
check 'role args option starts' wait_ready "$option_args"
check 'role args option reaches stub' suffix_is "$option_args" --model option-model

# Role defaults compose with the existing member, split, task and owner paths.
printf 'role task from file\n' >"$tmp/task"
role_spawn --role reviewer --name member --member --split main --message-file "$tmp/task"
member_pane="$(pane_of claude-project-member)"
check 'role member split starts' wait_ready "$member_pane"
check 'role member marker' test "$(tmux show-options -pqv -t "$member_pane" @member)" = 1
check 'role message-file reaches prompt' grep -Fq 'role task from file' "$(args_file "$member_pane")"
role_spawn --role reviewer --name owned --for claude-project-member
owned="$(pane_of claude-project-owned)"
check 'role with --for starts' wait_ready "$owned"
check 'role with --for keeps owner' test "$(tmux show-options -pqv -t "$owned" @parent)" = "$member_pane"

check 'main role rejected' rejects_with 'main is started by the user, not spawned' --role main
check 'unknown role rejected' rejects_with "unknown chain role 'mystery'" --role mystery
check 'missing role rejected' rejects_with '--role needs a role' --role
for incompatible in --resume --resume-id; do
  check "$incompatible rejects role" rejects_with '--role is only for new agents' --role runner "$incompatible" missing
done
for incompatible in --here --list-closed; do
  check "$incompatible rejects role" rejects_with '--role is only for new agents' --role runner "$incompatible"
done

[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
