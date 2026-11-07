#!/usr/bin/env bash
# Agent CLI arguments survive spawn, tmux shell parsing and resume.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-spawn-args-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-spawn-args.XXXXXX")"
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
printf '%s\0' "$@" >"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.args"
printf 'SPAWN STUB READY %s\n' "${0##*/}"
exec cat >>"$SPAWN_ARGS_LOG/${TMUX_PANE#%}.input"
STUB
  chmod +x "$tmp/bin/$kind"
done
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
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
rejects() {
  if "$@" >/dev/null 2>&1; then return 1; fi
}

# Spaces, quotes, empty strings, newlines, shell metacharacters and leading
# dashes survive the tmux command string as distinct literal arguments.
awkward=(--model claude-fable-5-1 "two words" "quote'\" \$HOME; *" "" $'line\nbreak' -dash)
spawn_agent claude --name forwarded -- "${awkward[@]}" </dev/null >"$tmp/spawn"
forwarded="$(pane_of claude-project-forwarded)"
check 'spawned Claude stub is ready' wait_ready "$forwarded"
check 'custom args follow generated Claude flags' suffix_is "$forwarded" "${awkward[@]}"
forwarded_id="$(tmux display-message -p -t "$forwarded" '#{@agent_id}')"
check 'session record stores the exact argument vector' recorded_args_are "$forwarded_id" "${awkward[@]}"

# Resume restores the recorded vector even though the caller supplies no args.
"$B/tmux-dismiss" --from main claude-project-forwarded >"$tmp/dismiss"
check 'first pane closed before resume' test -z "$(pane_of claude-project-forwarded)"
"$B/tmux-spawn" --resume claude-project-forwarded --from main </dev/null >"$tmp/resume"
resumed="$(pane_of claude-project-forwarded)"
check 'resumed agent is ready' wait_ready "$resumed"
check 'resume re-passes the saved arguments' suffix_is "$resumed" "${awkward[@]}"
check 'resume keeps the original Claude session' grep -Fq -- '--resume' "$(args_file "$resumed")"

# A task from a file remains the final prompt argument, after caller flags.
printf 'task from message file\n' >"$tmp/task"
spawn_agent codex --name file-task --message-file "$tmp/task" -- --model codex-file-model </dev/null >"$tmp/file-spawn"
file_pane="$(pane_of codex-project-file-task)"
check 'file task Codex stub is ready' wait_ready "$file_pane"
check 'message-file task and CLI args coexist' python3 - "$(args_file "$file_pane")" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
assert args[-3:-1] == [b"--model", b"codex-file-model"] and args[-1].startswith(b"[request from "), args[-3:]
assert b"task from message file" in args[-1], args[-1]
PY

# Stdin task input remains independent of the agent arguments.
printf 'task from stdin\n' | spawn_agent codex --name stdin-task -- --model codex-stdin-model >"$tmp/stdin-spawn"
stdin_pane="$(pane_of codex-project-stdin-task)"
check 'stdin task Codex stub is ready' wait_ready "$stdin_pane"
check 'stdin task is the prompt after agent args' python3 - "$(args_file "$stdin_pane")" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
assert args[-3:-1] == [b"--model", b"codex-stdin-model"] and args[-1].startswith(b"[request from "), args[-3:]
assert b"task from stdin" in args[-1], args[-1]
PY

# Visible member and --for splits use the same passthrough path.
spawn_agent claude --member --split main --name split-member -- --model member-model </dev/null >"$tmp/member-spawn"
member_pane="$(pane_of claude-project-split-member)"
check 'split member stub is ready' wait_ready "$member_pane"
check 'split member marker is set' test "$(tmux show-options -pqv -t "$member_pane" @member)" = 1
check 'split member receives agent args' suffix_is "$member_pane" --model member-model

spawn_agent claude --name owner </dev/null >"$tmp/owner-spawn"
owner_pane="$(pane_of claude-project-owner)"
check 'owner stub is ready' wait_ready "$owner_pane"
owner_name="$(tmux display-message -p -t "$owner_pane" '#{@agent}')"
spawn_agent codex --for "$owner_name" --split "$owner_pane" --size 30% --name for-split -- --model owner-child-model </dev/null >"$tmp/for-spawn"
for_pane="$(pane_of codex-project-for-split)"
check '--for split stub is ready' wait_ready "$for_pane"
check '--for split keeps the selected owner' test "$(tmux show-options -pqv -t "$for_pane" @parent)" = "$owner_pane"
check '--for split receives agent args' suffix_is "$for_pane" --model owner-child-model

# Executables without an agent adapter still receive every argument directly.
external_args=(--flag "space here" "" "quote'\"" -leading)
spawn_agent other-agent --name external -- "${external_args[@]}" </dev/null >"$tmp/external-spawn"
external_pane="$(pane_of other-agent-project-external)"
check 'other executable stub is ready' wait_ready "$external_pane"
check 'other executable receives exact args' suffix_is "$external_pane" "${external_args[@]}"

# Old task text after -- cannot be distinguished from a positional CLI value;
# the detectable single multi-word case warns, passes through, and sends no task.
spawn_agent claude --name old-separator -- 'Review src/auth.ts' </dev/null >"$tmp/old-separator" 2>"$tmp/old-separator-error"
old_pane="$(pane_of claude-project-old-separator)"
check 'old -- task form gives an actionable warning' grep -Fq 'arguments after -- go to the agent' "$tmp/old-separator-error"
check 'old -- task string is passed unchanged as an arg' suffix_is "$old_pane" 'Review src/auth.ts'
check 'old -- task string does not become a prompt' test "$(tmux show-options -pqv -t "$old_pane" @state)" = idle
check '--list-closed rejects agent arguments' rejects "$B/tmux-spawn" --list-closed -- --flag

[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
