#!/usr/bin/env bash
# Role claims recover missing kinds from process ancestry without replacing saved identity.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-role-kind-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-role-kind.XXXXXX")"
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
tmux set-option -p -t %0 @agent tmux-project-old
tmux split-window -d -t %0 "$tmp/bin/codex"
wait_marker %1
tmux set-option -p -t %1 @agent codex-project-peer
cd "$tmp/project"
run() { "$here/bin/tmux-agents" role "$@"; }
# ps is a data fixture: no real agent process or account is used.
ROLE_REAL_PS="$(command -v ps)"
ROLE_REAL_CAT="$(command -v cat)"
export ROLE_REAL_CAT
export ROLE_REAL_PS
export ROLE_OS=Darwin ROLE_PS_ENV="$tmp/env"
: > "$ROLE_PS_ENV"
export ROLE_PS_TREE="$tmp/tree" ROLE_PS_ARGS="$tmp/args"
cat > "$tmp/bin/ps" <<'STUB'
#!/bin/sh
case "$*" in
  '-axo pid=,ppid=,comm=') cat "$ROLE_PS_TREE" ;;
  '-E -p 91003 -o command=') cat "$ROLE_PS_ENV" ;;
  '-p 91003 -o args=') cat "$ROLE_PS_ARGS" ;;
  '-p '* ) exit 0 ;;
  *) exec "$ROLE_REAL_PS" "$@" ;;
esac
STUB
cat > "$tmp/bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' "$ROLE_OS"
STUB
cat > "$tmp/bin/cat" <<'STUB'
#!/bin/sh
if [ "$1" = /proc/91003/environ ]; then
  exec "$ROLE_REAL_CAT" "$ROLE_PS_ENV"
fi
exec "$ROLE_REAL_CAT" "$@"
STUB
chmod +x "$tmp/bin/ps" "$tmp/bin/uname" "$tmp/bin/cat"
export PATH="$tmp/bin:$PATH"
root="$(tmux display-message -p -t %0 '#{pane_pid}')"
. "$here/bin/lib.sh"
sid=12345678-1234-1234-1234-123456789abc
# A shell -> fish -> Claude process yields the actual kind, UUID and model.
cat > "$tmp/tree" <<TREE
$root 1 /bin/sh
91002 $root /usr/local/bin/fish
91003 91002 /path with spaces/claude
91004 1 /usr/local/bin/codex
TREE
printf 'claude --resume %s --model sonnet\n' "$sid" > "$tmp/args"
run main > "$tmp/out"
aid="$(pane_agent_id %0)"
[ "$(record_get "$aid" kind)" = claude ]
[ "$(record_get "$aid" id)" = "$sid" ]
[ "$(record_get "$aid" name)" = tmux-project-old ]
[ "$(record_get "$aid" dir)" = "$(pwd -P)" ]
"$here/bin/tmux-agents" board > "$tmp/board"
grep -Eq 'claude.*sonnet' "$tmp/board"
# An existing kind and hook-recorded ID survive a different process tree.
record_set "$aid" id hook-session
printf '%s 1 /bin/sh\n91003 %s /bin/codex\n' "$root" "$root" > "$tmp/tree"
run main > /dev/null
[ "$(record_get "$aid" kind)" = claude ]
[ "$(record_get "$aid" id)" = hook-session ]
# A partial record is filled, preserving the hook ID and unrelated metadata.
record_set "$aid" kind ''
record_set "$aid" custom keep
record_set "$aid" name saved-name
record_set "$aid" dir /saved/project
record_set "$aid" depth 7
run main > /dev/null
[ "$(record_get "$aid" kind)" = codex ]
[ "$(record_get "$aid" id)" = hook-session ]
[ "$(record_get "$aid" custom)" = keep ]
[ "$(record_get "$aid" name)" = saved-name ]
[ "$(record_get "$aid" dir)" = /saved/project ]
[ "$(record_get "$aid" depth)" = 7 ]
# A configured profile wrapper is preferred to its nested Codex process.
record_set "$aid" kind ''
export TMUX_AGENTS_CODEX_HOMES="account=$tmp/account"
printf '%s 1 /bin/sh\n91002 %s /bin/account\n91003 91002 /bin/codex\n' "$root" "$root" > "$tmp/tree"
run main > /dev/null
[ "$(record_get "$aid" kind)" = account ]
# Normal profile launches name the process codex and identify it by CODEX_HOME.
printf '%s 1 /bin/sh\n91003 %s /bin/codex\n' "$root" "$root" > "$tmp/tree"
record_set "$aid" kind ''
record_set "$aid" cli_args ''
printf 'codex -m gpt-test\n' > "$tmp/args"
printf 'codex -m gpt-test HOME=/other CODEX_HOME=%s OTHER=value\n' "$tmp/account" > "$tmp/env"
run main > /dev/null
[ "$(record_get "$aid" kind)" = account ]
"$here/bin/tmux-agents" board > "$tmp/board"
grep -Eq 'account.*gpt-test' "$tmp/board"
# Linux uses the NUL-delimited environment of the matched PID.
export ROLE_OS=Linux
record_set "$aid" kind ''
printf 'HOME=/other\0CODEX_HOME=%s\0OTHER=value\0' "$tmp/account" > "$tmp/env"
run main > /dev/null
[ "$(record_get "$aid" kind)" = account ]
# Unknown and unavailable environments keep ordinary Codex identity.
for mode in unknown unavailable; do
  record_set "$aid" kind ''
  if [ "$mode" = unknown ]; then printf 'CODEX_HOME=/unconfigured\0' > "$tmp/env"
  else rm "$tmp/env"; fi
  run main > /dev/null
  [ "$(record_get "$aid" kind)" = codex ]
done
export ROLE_OS=Darwin
: > "$tmp/env"
# An executable named after an unconfigured profile is not inferred as Codex.
record_set "$aid" kind ''
printf '%s 1 /bin/sh\n91003 %s /bin/unconfigured-profile\n' "$root" "$root" > "$tmp/tree"
run main > "$tmp/out" 2> "$tmp/err"
grep -q 'could not be detected' "$tmp/err"
[ -z "$(record_get "$aid" kind)" ]
# Shells remain excluded even when a recognized process exists below them.
printf '%s 1 /bin/sh\n91003 %s /bin/claude\n' "$root" "$root" > "$tmp/tree"
tmux set-option -p -t %0 @shell 1
if pane_agent_command %0 --detect > "$tmp/detected"; then exit 1; fi
[ ! -s "$tmp/detected" ]
tmux show-options -p -t %0 > "$tmp/before"
if run main > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'is a shell, not an agent' "$tmp/err"
tmux show-options -p -t %0 > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
tmux set-option -pu -t %0 @shell
# No identifiable descendant: unrelated agents and ancestry cycles are ignored.
record_set "$aid" kind ''
printf '%s 1 /bin/sh\n91003 1 /bin/claude\n91004 91005 /bin/codex\n91005 91004 /bin/sh\n' "$root" > "$tmp/tree"
run main > "$tmp/out" 2> "$tmp/err"
grep -q 'agent kind could not be detected' "$tmp/err"
[ -z "$(record_get "$aid" kind)" ]
[ "$(tmux show-option -pqv -t %0 @role)" = main ]
[ "$(tmux show-option -pqv -t %0 @tracked)" = 1 ]
# A plain Claude with no resume argument still gets a usable default record.
record_set "$aid" id ''
record_set "$aid" cli_args ''
printf '%s 1 /bin/sh\n91003 %s /bin/claude\n' "$root" "$root" > "$tmp/tree"
printf 'claude --resume some-label\n' > "$tmp/args"
run main > /dev/null
[ "$(record_get "$aid" kind)" = claude ]
[ -z "$(record_get "$aid" id)" ]
"$here/bin/tmux-agents" board > "$tmp/board"
grep -Eq 'claude.*default' "$tmp/board"
# UUID flags accept equals syntax too, and never overwrite the hook ID.
record_set "$aid" kind ''
printf 'claude --resume=%s\n' "$sid" > "$tmp/args"
run main > /dev/null
[ "$(record_get "$aid" id)" = "$sid" ]
record_set "$aid" kind ''
record_set "$aid" id hook-session
run main > /dev/null
[ "$(record_get "$aid" id)" = hook-session ]
echo 'ok role kind: wrapped Claude, Codex, profile, partial records, preserved IDs, unknown kind and board model'
