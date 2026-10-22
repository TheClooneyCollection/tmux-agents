#!/usr/bin/env bash
# Plain shell ownership, cwd, popup dispatch, identity exclusion and cleanup.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-shell-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-shell.XXXXXX")"
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
if [ "$1" = run-shell ] && [ "$2" = -b ]; then exec /bin/sh -c "$3"; fi
if [ "$1" = display-popup ]; then printf '%s\n' "$@" >"$SHELL_TEST_POPUP"; exit 0; fi
exec "$SHELL_TEST_TMUX" "$@"
STUB
# The bootstrap gate also invokes this wrapper inside a tmux-created pane.
# Export its dependencies to the private server, not just the test process.
tmux set-environment -g SHELL_TEST_TMUX "$real_tmux"
tmux set-environment -g SHELL_TEST_POPUP "$tmp/popup"
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH"
. "$B/lib.sh"
fail=0
check() { if "$@"; then printf 'ok %s\n' "$*"; else printf 'FAIL %s\n' "$*"; fail=1; fi; }
# Observe a command executed by the interactive shell before checking cwd or
# sending exit. A dead bootstrap pane must fail immediately, not time out.
shell_ready() {
  local pane="$1" marker="shell-ready:$1" command attempt ready
  ready="$(mktemp "$tmp/ready.XXXXXX")"
  # Keep the command on one line. Terminal echo and shell prompts cannot
  # satisfy this check: only executing the command writes the exact marker.
  printf -v command 'printf %%s %q > %q' "$marker" "$ready"
  tmux send-keys -t "$pane" "$command" Enter
  for ((attempt=0; attempt<200; attempt++)); do
    [ "$(tmux display -p -t "$pane" '#{pane_dead}')" = 0 ] || break
    if grep -Fxq "$marker" "$ready"; then rm -f "$ready"; return 0; fi
    sleep .02
  done
  rm -f "$ready"
  echo "FAIL interactive shell did not execute readiness marker: $pane" >&2
  tmux capture-pane -p -S -100 -t "$pane" >&2 || true
  return 1
}
# dash adds PS2 to output from multiline input; readiness must not depend
# on terminal rendering. Exercise it explicitly on hosts where sh is bash.
if command -v dash >/dev/null 2>&1; then
  dash_pane="$(tmux new-window -d -t work -P -F '#{pane_id}' "$(command -v dash) -i")"
  shell_ready "$dash_pane"
  tmux kill-pane -t "$dash_pane"
fi
# A live cat echoes the command but never executes it. A dead bootstrap also
# fails even if its scrollback happens to contain the expected marker.
if shell_ready %0 >"$tmp/echo-readiness.log" 2>&1; then
  echo 'FAIL terminal echo passed shell readiness'; fail=1
fi
# The child shell, not the test runner, expands TMUX_PANE.
# shellcheck disable=SC2016
dead_pane="$(tmux new-window -d -t work -P -F '#{pane_id}' 'printf "shell-ready:%s\n" "$TMUX_PANE"; exit 0')"
for ((i=0; i<100; i++)); do
  [ "$(tmux display -p -t "$dead_pane" '#{pane_dead}')" = 1 ] && break
  sleep .02
done
check test "$(tmux display -p -t "$dead_pane" '#{pane_dead}')" = 1
if shell_ready "$dead_pane" >"$tmp/dead-readiness.log" 2>&1; then
  echo 'FAIL dead pane passed shell readiness'; fail=1
fi
tmux kill-pane -t "$dead_pane"
tmux set -g @parent %999999
tmux set -g @member 1
tmux set -g @state working
"$B/tmux-shell" --pane %0 --client test-client
tmux set -gu @parent
tmux set -gu @member
tmux set -gu @state
first="$(tmux list-panes -a -F '#{pane_id} #{@shell}' | awk '$2 == 1 {print $1}')"
check test -n "$first"
shell_ready "$first"
check test "$(tmux show -pqv -t "$first" @parent)" = ''
check test "$(tmux show -pqv -t "$first" @member)" = 0
check test "$(tmux show -pqv -t "$first" @state)" = ''
check test "$(tmux show -pqv -t "$first" @tracked)" = 0
check test "$(tmux show -wqv -t "$first" remain-on-exit)" = off
check test "$(tmux show -pqv -t "$first" @shell_origin_window)" = "$(tmux display -p -t %0 '#{window_id}')"
check grep -q test-client "$tmp/popup"
check grep -q -- "--view $first" "$tmp/popup"
check test "$(tmux display -p -t "$first" '#{pane_current_path}')" = "$(cd "$tmp/project dir" && pwd -P)"
check test "$(tmux display -p -t "$first" '#{session_name}')" = "$(agents_session_for "$tmp/project dir")"
ensure_agent_ids "$tmp/queue"
check test "$(pane_agent_id "$first")" = ''
if ensure_agent_id "$first"; then echo 'FAIL shell accepted agent identity'; fail=1; fi
"$B/tmux-agent-report" --pane "$first" --turn-start
check test "$(tmux show -pqv -t "$first" @tracked)" = 0
agent_start_work "$first" working
check test "$(tmux show -pqv -t "$first" @started)" = ''
check test "$(tmux show -pqv -t "$first" @state)" = ''
"$B/tmux-shell" --from main --client test-client
second="$(tmux list-panes -a -F '#{pane_id} #{@shell} #{@parent}' | awk '$2 == 1 && $3 == "%0" {print $1}')"
check test -n "$second"
shell_ready "$second"
check test "$(pane_name "$first")" != "$(pane_name "$second")"
# A shell's own exit removes its pane despite global remain-on-exit.
tmux send-keys -t "$first" 'exit' Enter
for ((i=0; i<100; i++)); do
  if ! pane_alive "$first"; then break; fi
  sleep .02
done
if pane_alive "$first"; then echo 'FAIL shell exit retained pane'; fail=1; fi
# Closing the owning agent closes the shell without a session record.
"$B/tmux-dismiss" main
if pane_alive "$second"; then echo 'FAIL owner dismissal retained shell'; fail=1; fi
records="$(sessions_dir)"
for record in "$records"/*; do
  [ ! -f "$record" ] || { echo "FAIL unexpected record $record"; fail=1; }
done
exit "$fail"
