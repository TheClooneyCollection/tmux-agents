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
check 'default resolution printed separately' grep -Fxq 'role=runner agent=claude args="--model haiku" source=default' "$tmp/spawn"
runner="$(pane_of claude-project-runner)"
check 'runner starts Claude stub' wait_ready "$runner"
check 'runner pane role' test "$(tmux show-options -pqv -t "$runner" @role)" = runner
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
check 'secondary pane role canonicalized' test "$(tmux show-options -pqv -t "$interface" @role)" = interface
check 'secondary alias uses interface args' suffix_is "$interface" --model sonnet

spawn_agent codex --role runner --name different </dev/null >"$tmp/spawn" 2>"$tmp/warning"
check 'positional override explains dropped args' grep -Fxq 'tmux-spawn: warning: codex overrides role runner; role args dropped (pass -- ARGS to supply them)' "$tmp/warning"
check 'positional resolution' grep -Fxq 'role=runner agent=codex args="" source=positional' "$tmp/spawn"
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

# The alternative ordering accepts an agent after --role, before a task.
role_spawn --role runner codex --name after-role -- --model supplied 2>"$tmp/warning"
check 'explicit args suppress dropped-args warning' test ! -s "$tmp/warning"
after_role="$(pane_of codex-project-after-role)"
check 'agent after role starts' wait_ready "$after_role"
check 'replacement args survive override' suffix_is "$after_role" --model supplied

check 'PATH command after role requires quoted task' rejects_with 'quote the task text' --role worker git rebase onto main
check 'unknown word after role requires quoted task' rejects_with 'quote the task text' --role worker please inspect code
role_spawn --role worker --name quoted-task 'git rebase onto main'
quoted="$(pane_of codex-project-quoted-task)"
check 'quoted task retains configured worker' wait_ready "$quoted"
check 'quoted command text reaches agent prompt' grep -Fq 'git rebase onto main' "$(args_file "$quoted")"
TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile" role_spawn --role worker extra --name role-profile
check 'profile after role remains supported' wait_ready "$(pane_of codex-project-role-profile)"

tmux set-option -p -t %0 @role main
record_set "$(pane_agent_id %0)" kind claude
"$B/tmux-spawn" --from main --name plain </dev/null >"$tmp/spawn" 2>"$tmp/warning"
plain="$(pane_of claude-project-plain)"
check 'plain spawn starts' wait_ready "$plain"
check 'plain chain warning' grep -Fxq 'tmux-spawn: no --role; inheriting claude. Use --role ROLE to follow chain-config (or --plain to silence)' "$tmp/warning"
check 'plain resolution' grep -Fxq 'role=none agent=claude args="" source=inherited' "$tmp/spawn"
"$B/tmux-spawn" --from main --plain --name quiet </dev/null >"$tmp/spawn" 2>"$tmp/warning"
check 'plain flag silences warning' test ! -s "$tmp/warning"
check 'quiet spawn starts' wait_ready "$(pane_of claude-project-quiet)"

export TMUX_AGENTS_CHAIN_RUNNER=claude TMUX_AGENTS_CHAIN_RUNNER_ARGS='--model snapshot'
role_spawn --role runner --name snapshot
snapshot="$(pane_of claude-project-snapshot)"
check 'snapshot spawn starts' wait_ready "$snapshot"
check 'snapshot args beat changed option' suffix_is "$snapshot" --model snapshot
check 'snapshot resolution' grep -Fxq 'role=runner agent=claude args="--model snapshot" source=chain' "$tmp/spawn"
check 'snapshot agent forwarded' grep -Fxq 'TMUX_AGENTS_CHAIN_RUNNER=claude' "$SPAWN_ARGS_LOG/${snapshot#%}.env"
check 'snapshot args forwarded' grep -Fxq 'TMUX_AGENTS_CHAIN_RUNNER_ARGS=--model snapshot' "$SPAWN_ARGS_LOG/${snapshot#%}.env"
export TMUX_AGENTS_CHAIN_RUNNER_ARGS=''
role_spawn --role runner --name snapshot-empty --split main
snapshot_empty="$(pane_of claude-project-snapshot-empty)"
check 'empty snapshot split starts' wait_ready "$snapshot_empty"
check 'empty snapshot args suppress option and default' no_model "$snapshot_empty"
unset TMUX_AGENTS_CHAIN_RUNNER TMUX_AGENTS_CHAIN_RUNNER_ARGS

mission_id="$("$B/tmux-agents" mission add --from main 'Spawn mission')"
role_spawn --role reviewer --name mission-owner --mission "$mission_id"
mission_owner="$(pane_of claude-project-mission-owner)"
check 'mission owner starts' wait_ready "$mission_owner"
"$B/tmux-agents" mission show --from main "$mission_id" --log 3 >"$tmp/mission"
check 'spawn assigns mission owner' grep -Fq 'claude-project-mission-owner' "$tmp/mission"
check 'spawn logs canonical role' grep -Fq 'spawned claude-project-mission-owner (reviewer)' "$tmp/mission"
# A headless test server has no client: --open still creates the helper and
# surfaces the open command's precise error instead of silently ignoring it.
check 'open surfaces missing client' rejects_with 'no client showing the session' --role reviewer --name open-request --open
check 'open failure retains spawned agent' wait_ready "$(pane_of claude-project-open-request)"
check 'unknown mission rejected'  rejects_with 'unknown mission ID' --role runner --mission M999999 --name invalid-mission
check 'invalid mission creates no pane' test -z "$(pane_of claude-project-invalid-mission)"

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
