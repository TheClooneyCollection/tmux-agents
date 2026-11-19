#!/usr/bin/env bash
# Existing named agents claim their own role without changing assigned roles or active work.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-role-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-role.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE CLAUDECODE
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_PINNED=1
mkdir -p "$tmp/bin" "$tmp/project"
for agent in claude codex; do
  printf '#!/bin/sh\necho stub-agent\nexec cat\n' > "$tmp/bin/$agent"
  chmod +x "$tmp/bin/$agent"
done
export TMUX_SPAWN_BIN="$tmp/bin"
git -C "$tmp/project" init -q
printf 'HANDOFF.md\n' > "$tmp/project/.git/info/exclude"
printf 'PRIVATE HANDOFF BODY\n' > "$tmp/project/HANDOFF.md"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project" "$tmp/bin/claude"
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
wait_marker() {
  local pane="$1" attempt
  for ((attempt=0; attempt<100; attempt++)); do
    tmux capture-pane -p -t "$pane" > "$tmp/screen"
    if grep -q stub-agent "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  echo "stub marker missing in $pane" >&2; cat "$tmp/screen" >&2; return 1
}
wait_marker %0
tmux set-option -p -t %0 @agent claude-project-old
tmux split-window -d -t %0 "$tmp/bin/codex"
wait_marker %1
tmux set-option -p -t %1 @agent codex-project-peer
cd "$tmp/project"
run() { "$here/bin/tmux-agents" role "$@"; }
status() { "$here/bin/tmux-agents" status "$@"; }
reject() {
  if run "$@" > "$tmp/out" 2> "$tmp/err"; then
    printf 'unexpected successful claim: %s\n' "$*" >&2; exit 1
  fi
}
# Invalid requests leave both untracked panes untouched.
reject bogus
grep -q 'unknown chain role' "$tmp/err"
reject main --from unknown
reject main --from codex-project-peer
reject main --from %1
reject main --from %999
reject main extra
reject main --force
reject main --from
reject
[ -z "$(tmux show-option -pqv -t %0 @agent_id)" ]
[ -z "$(tmux show-option -pqv -t %1 @role)" ]
TMUX_AGENTS_PINNED='' reject main
status > "$tmp/status"
grep -q 'role=none' "$tmp/status"
grep -q '^no role claimed; run: tmux-agents role main --from claude-project-old$' "$tmp/status"
# Only the unparented caller receives the hint; peers never do.
tmux set-option -p -t %0 @peers %1
status codex-project-peer > "$tmp/status"
if grep -q 'no role claimed' "$tmp/status"; then exit 1; fi
tmux set-option -p -t %1 @parent %0
TMUX_PANE=%1 status > "$tmp/status"
if grep -q 'no role claimed' "$tmp/status"; then exit 1; fi
for role in main worker; do
  TMUX_PANE=%1 reject "$role"
  grep -q 'spawned helpers keep their assigned role' "$tmp/err"
done
[ -z "$(tmux show-option -pqv -t %1 @agent_id)" ]
[ -z "$(tmux show-option -pqv -t %1 @tracked)" ]
tmux set-option -pu -t %1 @parent
# Failed identity or accounting initialization must not enable tracking.
mkdir -p "$tmp/failbin"
ROLE_REAL_TMUX="$(command -v tmux)"
export ROLE_REAL_TMUX
cat > "$tmp/failbin/tmux" <<'STUB'
#!/bin/sh
for arg in "$@"; do
  if [ "$1" = set-option ] && [ "$arg" = "$ROLE_FAIL_OPTION" ]; then exit 1; fi
done
exec "$ROLE_REAL_TMUX" "$@"
STUB
chmod +x "$tmp/failbin/tmux"
ROLE_FAIL_OPTION=@agent_id PATH="$tmp/failbin:$PATH" reject main
grep -q 'could not initialize agent identity' "$tmp/err"
[ -z "$(tmux show-option -pqv -t %0 @tracked)" ]
[ -z "$(tmux show-option -pqv -t %0 @role)" ]
ROLE_FAIL_OPTION=@state PATH="$tmp/failbin:$PATH" reject main
grep -q 'could not initialize agent tracking' "$tmp/err"
[ -z "$(tmux show-option -pqv -t %0 @tracked)" ]
[ -z "$(tmux show-option -pqv -t %0 @role)" ]
# A legacy main becomes a tracked, idle agent with stable identity.
run main --from claude-project-old > "$tmp/out"
grep -qx 'role: main (pane %0)' "$tmp/out"
[ "$(tmux show-option -pqv -t %0 @role)" = main ]
[ "$(tmux show-option -pqv -t %0 @tracked)" = 1 ]
[ "$(tmux show-option -pqv -t %0 @state)" = idle ]
aid="$(tmux show-option -pqv -t %0 @agent_id)"
[[ "$aid" =~ ^a[0-9a-f]{12}$ ]]
status > "$tmp/status"
grep -q 'role=main' "$tmp/status"
if grep -q 'no role claimed' "$tmp/status"; then exit 1; fi
# Retry and conflict preserve active work and identity, including attention.
tmux set-option -p -t %0 @state needs_you
tmux set-option -p -t %0 @attention_since 123
tmux set-option -p -t %0 @worked 42
tmux show-options -p -t %0 > "$tmp/before"
run main > /dev/null
TMUX_AGENTS_PINNED='' run main --from claude-project-old > /dev/null
reject worker
grep -q "already has role 'main'" "$tmp/err"
tmux show-options -p -t %0 > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
# The legacy alias is canonicalized, and missing identity alone preserves state.
tmux set-option -p -t %1 @tracked 1
tmux set-option -p -t %1 @state working
TMUX_PANE=%1 run secondary > "$tmp/out"
[ "$(tmux show-option -pqv -t %1 @role)" = interface ]
[ "$(tmux show-option -pqv -t %1 @state)" = working ]
[ -n "$(tmux show-option -pqv -t %1 @agent_id)" ]
TMUX_PANE=%1 run secondary > /dev/null
TMUX_PANE=%1 reject main
# Every documented role is accepted on an unassigned pane.
for role in designer worker reviewer runner researcher; do
  tmux set-option -pu -t %1 @role
  TMUX_PANE=%1 run "$role" > /dev/null
  [ "$(tmux show-option -pqv -t %1 @role)" = "$role" ]
done
# Unnamed callers are never auto-named; shell and exited panes cannot claim.
tmux set-option -pu -t %1 @role
tmux set-option -pu -t %1 @agent
TMUX_PANE=%1 reject main
TMUX_PANE=%1 reject main --from unknown
[ -z "$(tmux show-option -pqv -t %1 @agent)" ]
tmux set-option -p -t %1 @agent codex-project-peer
tmux set-option -p -t %1 @shell 1
TMUX_PANE=%1 reject main
tmux set-option -pu -t %1 @shell
tmux set-option -w -t %1 remain-on-exit on
tmux send-keys -t %1 C-d
for ((attempt=0; attempt<100; attempt++)); do
  [ "$(tmux display-message -p -t %1 '#{pane_dead}')" != 1 ] || break
  sleep 0.05
done
[ "$(tmux display-message -p -t %1 '#{pane_dead}')" = 1 ]
TMUX_PANE=%1 reject main
[ -z "$(tmux show-option -pqv -t %1 @role)" ]
"$here/bin/tmux-agents" --help > "$tmp/help"
grep -q 'role ROLE' "$tmp/help"
run --help | grep -q 'usage: tmux-agents role ROLE'
echo 'ok role claim, alias, caller guards, conflict, idempotence, tracking and status hint'
