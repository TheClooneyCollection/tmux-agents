#!/usr/bin/env bash
# Exact command execution, status, countdown, ownership and persistent clearing.
# Predicates and shell snippets are invoked indirectly.
# shellcheck disable=SC2016,SC2329
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-command-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-command.XXXXXX")"
real_tmux="$(command -v tmux)"
mkdir -p "$tmp/bin" "$tmp/project dir"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin"
for a in claude codex; do
  printf '#!/bin/sh\necho "FAKE %s"\nexec cat\n' "$a" >"$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
  "$tmp/bin/$a" </dev/null | grep -qx "FAKE $a"
done
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project dir" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -g remain-on-exit on
tmux set -p -t %0 @agent main
tmux new-window -d -t work -n sentinel cat
# Only popup display is intercepted; all lifecycle operations use real tmux.
export SHELL_TEST_TMUX="$real_tmux" SHELL_TEST_POPUP="$tmp/popup"
cat >"$tmp/bin/tmux" <<'STUB'
#!/bin/sh
if [ "${COMMAND_TEST_FAIL_METADATA:-}" = 1 ] && [ "$1" = set-option ] && [ "${5:-}" = @shell ]; then
  printf '%s' "$4" >"$SHELL_TEST_POPUP.failed-pane"
  exit 1
fi
if [ "$1" = run-shell ] && [ "$2" = -b ]; then exec /bin/sh -c "$3"; fi
if [ "$1" = display-popup ]; then printf '%s\n' "$@" >"$SHELL_TEST_POPUP"; exit 0; fi
exec "$SHELL_TEST_TMUX" "$@"
STUB
tmux set-environment -g SHELL_TEST_TMUX "$real_tmux"
tmux set-environment -g SHELL_TEST_POPUP "$tmp/popup"
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH"
. "$B/lib.sh"
fail=0
check() { if "$@"; then printf 'ok %s\n' "$*"; else printf 'FAIL %s\n' "$*"; fail=1; fi; }

# Poll an explicit predicate, never infer completion from directory file counts.
wait_for() {
  local n
  for ((n=0; n<200; n++)); do if "$@"; then return 0; fi; sleep .02; done
  echo "timeout: $*" >&2
  tmux capture-pane -p -t "${pane:-%0}" >&2 || true
  tmux show -p -t "${pane:-%0}" >&2 || true
  return 1
}
record_status() { grep -qx "status=$2" "$1"; }
gone() { ! pane_alive "$1"; }
open_command() {
  local result
  result="$("$B/tmux-shell" --pane %0 --client test-client --command "$1")"
  pane="${result##*(}"; pane="${pane%)}"
  id="$(tmux show -pqv -t "$pane" @shell_command_id)"
  record="$(shell_commands_dir)/$id.record"
}
# Picker cancellation must not create a hidden pane.
before_pick="$(tmux list-panes -a -F '#{pane_id}')"
"$B/tmux-shell" --pane %0 --client test-client --pick
check test "$(tmux list-panes -a -F '#{pane_id}')" = "$before_pick"
export TMUX_AGENTS_SHELL_CLOSE_SECS=20
open_command 'printf "%s\n" '\''a $HOME; "quoted"'\''; printf "line two\n"'
wait_for record_status "$record" ok
check test "$(tmux show -pqv -t "$pane" @shell)" = 1
check test "$(tmux show -pqv -t "$pane" @agent_id)" = ''
check test "$(tmux display -p -t "$pane" '#{pane_current_path}')" = "$(cd "$tmp/project dir" && pwd -P)"
wait_for /bin/sh -c 'test "$(tmux show -pqv -t "$1" @shell_exit_code)" = 0' _ "$pane"
check test "$(sed -n 's/^parent=//p' "$record")" = ''
check test "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 0777' "$record")" = 600
wait_for /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -q "Closing in"' _ "$pane"
tmux send-keys -t "$pane" x
wait_for /bin/sh -c 'tmux display -p -t "$1" "#{pane_current_command}" | grep -Eq "^(ba)?sh$"' _ "$pane"
check pane_alive "$pane"
check /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -F '\''a $HOME; "quoted"'\''' _ "$pane"
"$B/tmux-shell" --clear-command "$id"
check gone "$pane"
check test ! -e "$record"
check test ! -e "${record%.record}.command"
open_command 'exit 7'
wait_for record_status "$record" 'failed 7'
wait_for /bin/sh -c 'test "$(tmux show -pqv -t "$1" @shell_status)" = "failed 7"' _ "$pane"
wait_for /bin/sh -c 'tmux display -p -t "$1" "#{pane_current_command}" | grep -Eq "^(ba)?sh$"' _ "$pane"
tmux send-keys -t "$pane" exit Enter
wait_for gone "$pane"
check test -f "$record"
"$B/tmux-shell" --clear-command "$id"
# Interrupt a foreground command and retain the resulting interactive shell.
open_command 'printf "interrupt-ready\n"; exec sleep 30'
wait_for /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -q interrupt-ready' _ "$pane"
tmux send-keys -t "$pane" C-c
wait_for record_status "$record" 'failed 130'
wait_for /bin/sh -c 'tmux display -p -t "$1" "#{pane_current_command}" | grep -Eq "^(ba)?sh$"' _ "$pane"
# Existing shell guards apply equally to command panes.
if "$B/tmux-ask" --from main --any "$(pane_name "$pane")" blocked; then fail=1; fi
if "$B/tmux-shell" --from "$(pane_name "$pane")" --client test-client --command true; then fail=1; fi
"$B/tmux-shell" --clear-command "$id"
# Configured fish syntax and functions are evaluated by fish itself.
if command -v fish >/dev/null 2>&1; then
  mkdir -p "$tmp/config/fish"
  printf 'function command_fixture; printf "fish-function-ok\\n"; end\n' >"$tmp/config/fish/config.fish"
  tmux set-environment -g XDG_CONFIG_HOME "$tmp/config"
  tmux set -g default-shell "$(command -v fish)"
  open_command "command_fixture; set value 'fish \$ literal'; printf '%s\\n' \"\$value\""
  wait_for record_status "$record" ok
  check /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -qx fish-function-ok' _ "$pane"
  check /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -Fx "fish $ literal"' _ "$pane"
  "$B/tmux-shell" --clear-command "$id"
  tmux set -g default-shell /bin/sh
  tmux set-environment -gu XDG_CONFIG_HOME
fi
# Natural countdown completion closes the pane and retains the result.
export TMUX_AGENTS_SHELL_CLOSE_SECS=1
open_command true
wait_for record_status "$record" ok
wait_for gone "$pane"
check test -f "$record"
"$B/tmux-shell" --clear-command "$id"
# Zero closes only after the command completes, retaining the exact raw bytes.
export TMUX_AGENTS_SHELL_CLOSE_SECS=0
raw=$'printf "multi\\n"\nprintf "done\\n"\n\n'
result="$("$B/tmux-shell" --pane %0 --client test-client --command "$raw")"
pane="${result##*(}"; pane="${pane%)}"
record="$(grep -lFx "pane=$pane" "$(shell_commands_dir)"/*.record)"
id="${record##*/}"; id="${id%.record}"
wait_for record_status "$record" ok
wait_for gone "$pane"
check cmp "${record%.record}.command" <(printf '%s' "$raw")
"$B/tmux-shell" --clear-command "$id"
if TMUX_AGENTS_SHELL_CLOSE_SECS=no "$B/tmux-shell" --pane %0 --client test-client --command true; then fail=1; fi
# Failed setup kills the gated pane and deletes unpublished command files.
if COMMAND_TEST_FAIL_METADATA=1 "$B/tmux-shell" --pane %0 --client test-client --command 'printf setup-failure-unique'; then fail=1; fi
check gone "$(cat "$tmp/popup.failed-pane")"
if grep -l setup-failure-unique "$(shell_commands_dir)"/*.command 2>/dev/null; then fail=1; fi
# A killed lock holder releases the advisory lock automatically.
perl -MFcntl=:flock -e 'open my $f, ">>", $ARGV[0] or die $!; flock($f, LOCK_EX) or die $!; open my $ready, ">", $ARGV[1] or die $!; close $ready; sleep 60' "$(shell_commands_dir)/.lock" "$tmp/lock-ready" &
lock_pid=$!
wait_for test -f "$tmp/lock-ready"
kill -KILL "$lock_pid"
wait "$lock_pid" 2>/dev/null || true
export TMUX_AGENTS_SHELL_CLOSE_SECS=20
open_command 'printf "forced-ready\n"; exec sleep 30'
wait_for /bin/sh -c 'tmux capture-pane -p -t "$1" | grep -q forced-ready' _ "$pane"
tmux kill-pane -t "$pane"
"$B/tmux-shell" --clear-command "$id" &
clear_pid=$!
wait_for test ! -e "$record"
wait "$clear_pid"
check test ! -e "${record%.record}.command"
# Clearing concurrent with completion must never resurrect a record.
open_command "while [ ! -f '$tmp/release-command' ]; do sleep .01; done"
check record_status "$record" running
"$B/tmux-shell" --clear-command "$id" &
clear_pid=$!
touch "$tmp/release-command"
wait_for test ! -e "$record"
wait "$clear_pid"
check gone "$pane"
check test ! -e "$record"
export TMUX_AGENTS_SHELL_CLOSE_SECS=0
# Finished command records are removed when their stable owner is dismissed.
result="$("$B/tmux-shell" --from main --client test-client --command true)"
pane="${result##*(}"; pane="${pane%)}"
record="$(grep -lFx "pane=$pane" "$(shell_commands_dir)"/*.record)"
wait_for record_status "$record" ok
wait_for gone "$pane"
check test "$(sed -n 's/^parent=//p' "$record")" = "$(pane_agent_id %0)"
# --keep-children disowns live panes and completed records consistently.
keeper="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
tmux set -p -t "$keeper" @agent keeper \; set -p -t "$keeper" @parent %0
kept_result="$("$B/tmux-shell" --from keeper --client test-client --command 'exit 8')"
kept_pane="${kept_result##*(}"; kept_pane="${kept_pane%)}"
kept_record="$(grep -lFx "pane=$kept_pane" "$(shell_commands_dir)"/*.record)"
wait_for record_status "$kept_record" 'failed 8'
completed_result="$("$B/tmux-shell" --from keeper --client test-client --command true)"
completed_pane="${completed_result##*(}"; completed_pane="${completed_pane%)}"
completed_record="$(grep -lFx "pane=$completed_pane" "$(shell_commands_dir)"/*.record)"
wait_for gone "$completed_pane"
"$B/tmux-dismiss" --keep-children keeper
check pane_alive "$kept_pane"
check test "$(tmux show -pqv -t "$kept_pane" @parent)" = ''
check grep -qx parent= "$kept_record"
check grep -qx parent_name= "$kept_record"
check grep -qx parent= "$completed_record"
check grep -qx parent_name= "$completed_record"
# Descendant ownership is cleared before the owning agent identity disappears.
child="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
tmux set -p -t "$child" @agent child \; set -p -t "$child" @parent %0
child_result="$("$B/tmux-shell" --from child --client test-client --command 'exit 9')"
child_pane="${child_result##*(}"; child_pane="${child_pane%)}"
child_record="$(grep -lFx "pane=$child_pane" "$(shell_commands_dir)"/*.record)"
wait_for record_status "$child_record" 'failed 9'
"$B/tmux-dismiss" main
check test ! -e "$record"
check test ! -e "$child_record"
check gone "$child_pane"
check pane_alive "$kept_pane"
check test -f "$completed_record"
kept_id="${kept_record##*/}"; completed_id="${completed_record##*/}"
"$B/tmux-shell" --clear-command "${kept_id%.record}"
"$B/tmux-shell" --clear-command "${completed_id%.record}"
exit "$fail"
