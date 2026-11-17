#!/usr/bin/env bash
# Open exact live names on the caller's newest client, with no real tmux server.
# Literal tmux session IDs, not shell positional parameters.
# shellcheck disable=SC2016
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-open.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export OPEN_TEST_ROOT="$tmp" TMUX_AGENTS_PREFIX=agents
export PATH="$tmp/bin:$PATH"
unset TMUX_PANE TMUX_AGENTS_PINNED CLAUDECODE
export XDG_STATE_HOME="$tmp/state" TMUX="$tmp/socket-open-$$,1,0"
cat >"$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
  list-sessions) exit 0 ;;
  list-panes)
    case "$4" in
      '#{pane_id}') printf '%%1\n%%2\n%%3\n' ;;
      '#{pane_id} #{@agent}') printf '%%1 caller\n%%2 target\n%%3 target-extra\n' ;;
      *) printf '%%1\tcaller\t\t\t0\n%%2\ttarget\t\t\t0\n' ;;
    esac ;;
  set-option) printf '%s\n' "$*" >>"$OPEN_TEST_ROOT/migration" ;;
  run-shell)
    [ "$2" = -b ] || exit 1
    [ "${OPEN_FAIL:-0}" != 1 ] || exit 1
    printf '%s' "$3" >"$OPEN_TEST_ROOT/popup-command" ;;
  display-popup)
    printf '%s\n' "$@" >"$OPEN_TEST_ROOT/popup-args"
    printf '%s' "${!#}" >"$OPEN_TEST_ROOT/viewer-command"
    printf '%s\n' "$*" >>"$OPEN_TEST_ROOT/actions" ;;

  show-options) [ "${OPEN_SHELL:-0}" != 1 ] || echo 1 ;;
  display-message)
    if [ "$2" = -c ]; then printf '%s\n' "$*" >>"$OPEN_TEST_ROOT/actions"; exit 0; fi
    case "$5" in
      '#{@agent}') echo target ;;
      '#{pane_dead}') echo "${OPEN_DEAD:-0}" ;;
      '#{session_id}') echo '$1' ;;
      '#{session_name}') echo "${OPEN_SESSION:-work}" ;;
      *) echo "unexpected format: $*" >&2; exit 1 ;;
    esac ;;
  list-clients) cat "$OPEN_TEST_ROOT/clients" ;;
  switch-client)
    printf '%s\n' "$*" >>"$OPEN_TEST_ROOT/actions"
    [ "${OPEN_FAIL:-0}" != 1 ] ;;
  *) echo "unexpected tmux call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/tmux"
printf 'old\t$1\t9\nnew\t$1\t100\nunrelated\t$2\t999\nolder\t$1\t8\n' >"$tmp/clients"
run() { "$here/bin/tmux-agents" open "$@"; }
reject() {
  : >"$tmp/actions"
  if run "$@" >"$tmp/out" 2>"$tmp/err"; then echo "unexpected success: $*" >&2; exit 1; fi
  [ ! -s "$tmp/out" ] && [ -s "$tmp/err" ]
  [ ! -s "$tmp/actions" ]
}
[ "$(run target --from caller)" = 'opened target' ]
grep -Fx 'switch-client -c new -t %2' "$tmp/actions"
grep -Fx 'display-message -c new -d 4000 jumped to target · prefix + L to go back' "$tmp/actions"
echo 'ok visible target opens on newest matching session client'
[ -f "$XDG_STATE_HOME/tmux-agents/socket-open-$$/sessions/.ids-v1" ]
grep -q '@agent_id' "$tmp/migration"
[ "$(run target --from %1)" = 'opened target' ]
reject target --from %99
echo 'ok legacy identity initialization and pane-id caller'
: >"$tmp/actions"
[ "$(OPEN_SESSION=agents-project run --from caller target)" = 'opened target in a popup' ]
[ -s "$tmp/popup-command" ]
[ ! -s "$tmp/actions" ]
/bin/sh "$tmp/popup-command"
grep -F 'display-popup -c new -E -w 90% -h 90%' "$tmp/actions"
grep -F -- "--view '%2' 'new' window sub" "$tmp/actions"
if grep -q switch-client "$tmp/actions"; then exit 1; fi
grep -Fx ' target  (prefix + d: back to the list) ' "$tmp/popup-args"
echo 'ok hidden target schedules existing viewer without waiting for popup'
# Exercise both shell parsing layers with quotes and spaces in paths and client.
quoted="$tmp/agent's folder"
mkdir "$quoted"
cp "$here/bin/tmux-agents-open" "$here/bin/lib.sh" "$here/bin/turn-state.sh" "$quoted/"
cat >"$quoted/tmux-agents" <<'VIEWER'
#!/bin/sh
printf '%s\n' "$@" >"$OPEN_TEST_ROOT/viewer-args"
VIEWER
chmod +x "$quoted/tmux-agents"
printf "client's terminal\t\$1\t100\n" >"$tmp/clients"
OPEN_SESSION=agents-project "$quoted/tmux-agents-open" target --from %1 >"$tmp/out"
/bin/sh "$tmp/popup-command"
/bin/sh "$tmp/viewer-command"
python3 - "$tmp" <<'ASSERT'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
args = root.joinpath('popup-args').read_text().splitlines()
assert args[args.index('-c') + 1] == "client's terminal", args
assert args[args.index('-T') + 1] == ' target  (prefix + d: back to the list) ', args
assert root.joinpath('viewer-args').read_text().splitlines() == ['--view', '%2', "client's terminal", 'window', 'sub']
ASSERT
echo 'ok popup title and nested shell quoting preserve client and executable path'
reject missing --from caller
reject targ --from caller
reject %2 --from caller
reject target --from missing
reject target
reject --from caller
reject target --from
reject target --from caller --from caller
reject target --from caller extra
reject target --from caller --unknown
OPEN_DEAD=1 reject target --from caller
OPEN_SHELL=1 reject target --from caller
echo 'ok missing, partial, pane-id, dead, shell and malformed inputs rejected'
printf 'unrelated\t$2\t999\n' >"$tmp/clients"
reject target --from caller
grep -q 'no client' "$tmp/err"
echo 'ok unrelated clients never used'
printf 'only\t$1\t0\n' >"$tmp/clients"
[ "$(run target --from caller)" = 'opened target' ]
grep -Fx 'switch-client -c only -t %2' "$tmp/actions"
echo 'ok single client with zero activity'
if OPEN_FAIL=1 run target --from caller >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
[ ! -s "$tmp/out" ]
if OPEN_FAIL=1 OPEN_SESSION=agents-project run target --from caller >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
[ ! -s "$tmp/out" ]
echo 'ok failed switch or popup scheduling does not report success'
[ "$(TMUX_AGENTS_PINNED=1 TMUX_PANE=%1 run target)" = 'opened target' ]
[ "$(CLAUDECODE=1 TMUX_PANE=%1 run target)" = 'opened target' ]
TMUX_PANE=%1 reject target
run --help | grep -F 'open NAME [--from ME]'
echo 'PASS: open'
