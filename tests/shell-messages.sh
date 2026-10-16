#!/usr/bin/env bash
# Shell message boundaries: direct, reply, stale queued identity and retry.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-shell-messages-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/shell-messages.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
Q="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s test cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux new-window -d -t test /bin/sh
tmux set -p -t %0 @agent sender
tmux set -p -t %1 @agent terminal
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
receiver_id="$(pane_agent_id %1)"
# Preserve a stale/forged identity to exercise the final delivery boundary.
tmux set -p -t %1 @shell 1
tmux set -p -t %1 @tracked 0
tmux set -p -t %0 @peers %1
tmux set -p -t %1 @peers %0
mkdir -p "$tmp/bin" "$Q"
SHELL_MESSAGE_TMUX="$(command -v tmux)"
export SHELL_MESSAGE_TMUX SHELL_MESSAGE_CALLS="$tmp/calls"
cat > "$tmp/bin/tmux" <<'WRAP'
#!/bin/sh
case "$1" in
  load-buffer|paste-buffer|send-keys) printf '%s\n' "$*" >> "$SHELL_MESSAGE_CALLS" ;;
  run-shell) exit 0 ;;
esac
exec "$SHELL_MESSAGE_TMUX" "$@"
WRAP
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH"
check() { if "$@"; then echo "ok $*"; else echo "FAIL $*"; exit 1; fi; }
rejected() {
  if "$B/tmux-ask" "$@" >"$tmp/result" 2>&1; then cat "$tmp/result"; return 1; fi
  grep -q 'terminal is a shell, not an agent' "$tmp/result"
}
payload="touch '$tmp/executed'"
check rejected --from sender terminal "$payload"
check rejected --from sender --any terminal "$payload"
check rejected --from sender --reply terminal "$payload"
check rejected --from sender --any --reply %1 "$payload"
check rejected --from terminal --any sender "$payload"
check rejected --system-notice %1 "$payload"
# --retry-locked is the internal retry path, avoiding the shared retry lock.
check rejected --retry-locked --to terminal
check rejected --retry --to terminal
fixture() {
  local body="$Q/$1-$$-1.$2"
  printf '%s\n' "$payload" > "$body"
  printf 'from_name=tmux-ask\nto_id=%s\nto_pane=%%1\nto_name=terminal\nkind=request\n' "$receiver_id" >"${body%.*}.meta"
}
fixture 100 msg
"$B/tmux-ask" --attempt %1 "$Q/100-$$-1.msg"
check test -f "$Q/100-$$-1.undelivered"
check grep -Fxq "$payload" "$Q/100-$$-1.undelivered"
fixture 101 msg
"$B/tmux-ask" --deliver %1 "$Q/101-$$-1.msg"
check test -f "$Q/101-$$-1.undelivered"
fixture 102 msg
"$B/tmux-ask" --kick %1
check test -f "$Q/102-$$-1.undelivered"
fixture 103 sending
"$B/tmux-ask" --retry-locked
check test -f "$Q/103-$$-1.undelivered"
check grep -Fxq "$payload" "$Q/103-$$-1.undelivered"
check test ! -e "$tmp/calls"
check test ! -e "$tmp/executed"
if tmux capture-pane -p -t %1 | grep -Fq "$payload"; then
  echo 'FAIL payload reached shell'; exit 1
fi
echo 'PASS shell message boundaries'
