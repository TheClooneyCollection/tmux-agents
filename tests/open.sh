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
unset TMUX TMUX_PANE
cat >"$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
  list-sessions) exit 0 ;;
  list-panes) printf '%%1 caller\n%%2 target\n%%3 target-extra\n';;
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
  switch-client|display-popup)
    printf '%s\n' "$*" >>"$OPEN_TEST_ROOT/actions"
    [ "${OPEN_FAIL:-0}" != 1 ] ;;
  *) echo "unexpected tmux call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/tmux"
printf 'old\t$1\t9\nunrelated\t$2\t999\nnew\t$1\t100\n' >"$tmp/clients"
run() { "$here/bin/tmux-agents" open "$@"; }
reject() {
  : >"$tmp/actions"
  if run "$@" >"$tmp/out" 2>"$tmp/err"; then echo "unexpected success: $*" >&2; exit 1; fi
  [ ! -s "$tmp/out" ] && [ -s "$tmp/err" ]
  [ ! -s "$tmp/actions" ]
}
[ "$(run target --from caller)" = 'opened target' ]
grep -Fx 'switch-client -c new -t %2' "$tmp/actions"
grep -F 'jumped to target · prefix + L to go back' "$tmp/actions"
echo 'ok visible target opens on newest matching session client'
: >"$tmp/actions"
[ "$(OPEN_SESSION=agents-project run --from caller target)" = 'opened target in a popup' ]
grep -F 'display-popup -c new -E -w 90% -h 90%' "$tmp/actions"
grep -F -- "--view '%2' 'new' window sub" "$tmp/actions"
if grep -q switch-client "$tmp/actions"; then exit 1; fi
echo 'ok hidden target uses existing viewer'
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
echo 'ok failed switch or popup does not report success'
run --help | grep -F 'open NAME --from ME'
echo 'PASS: open'
