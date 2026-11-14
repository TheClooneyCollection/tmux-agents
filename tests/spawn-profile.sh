#!/usr/bin/env bash
# Spawn profile inheritance: caller identity, explicit choices and saved resumes.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-spawn-profile-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-spawn-profile.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project"
for kind in claude codex; do
  cat >"$tmp/bin/$kind" <<'STUB'
#!/bin/sh
resume=no
for arg do
  case "$arg" in resume|--resume) resume=yes ;; esac
done
printf 'HOME=%s\n' "${CODEX_HOME:-default}"
printf 'STUB READY %s RESUME=%s\n' "${0##*/}" "$resume"
exec cat
STUB
  chmod +x "$tmp/bin/$kind"
done
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_SUB_AUTO
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 -c "$tmp/project" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0 count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
spawn() { "$B/tmux-spawn" "$@" --from main </dev/null >"$tmp/spawn"; }
ready() {
  local pane="$1" kind="$2" i
  [ -n "$pane" ] || return 1
  for ((i=0; i<100; i++)); do
    tmux capture-pane -p -J -t "$pane" -S -100 >"$tmp/screen"
    if grep -q "STUB READY $kind " "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  return 1
}
export TMUX_AGENTS_CODEX_HOMES="second=$tmp/second other=$tmp/other"
main_id="$(pane_agent_id %0)"
record_set "$main_id" kind second
# A shared daemon carries a different caller's environment.
export TMUX_AGENTS_KIND=codex CODEX_HOME="$tmp/other"
expect_home() {
  local name="$1" home="$2"
  ready "$(pane_of "$name")" codex || { echo "ABORT: $name stub not ready"; exit 1; }
  check "$name launches on $home" grep -Fxq "HOME=$home" "$tmp/screen"
}
spawn --exact --name inherited
expect_home inherited "$tmp/second"
spawn other --exact --name explicit
expect_home explicit "$tmp/other"
tmux set-environment -g CODEX_HOME "$tmp/other"
spawn codex --exact --name plain
expect_home plain default
# The saved profile wins even after the parent's profile changes.
aid="$(pane_agent_id "$(pane_of inherited)")"
record_set "$aid" id saved-conversation
"$B/tmux-dismiss" --from main inherited >/dev/null
record_set "$main_id" kind other
spawn --resume inherited
expect_home inherited "$tmp/second"
check 'resume uses conversation adapter' grep -Fq 'RESUME=yes' "$tmp/screen"
"$B/tmux-dismiss" --from main inherited >/dev/null
spawn other --resume-id "$aid"
expect_home inherited "$tmp/other"
"$B/tmux-dismiss" --from main inherited >/dev/null
spawn --resume-id "$aid"
expect_home inherited "$tmp/other"
# Legacy records without a kind use their live parent's profile.
"$B/tmux-dismiss" --from main inherited >/dev/null
record_set "$aid" kind ''
spawn --resume-id "$aid"
expect_home inherited "$tmp/other"
record_set "$main_id" kind codex
spawn --exact --name plain-parent
expect_home plain-parent default
# Without a record, a mapped CODEX_HOME refines a generic codex pin.
record_set "$main_id" kind ''
spawn --exact --name home-fallback
expect_home home-fallback "$tmp/other"
[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
