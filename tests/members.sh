#!/usr/bin/env bash
# Member spawn, caller restrictions and depth, resume and cleanup on an isolated tmux server.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-members-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-members.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  # shellcheck disable=SC2016
  printf '#!/bin/sh\necho "FAKE %s $*"\necho "DEPTH=$TMUX_AGENTS_DEPTH"\nexec cat\n' "$a" >"$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0 TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 40 -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0
count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
alive() { tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$1"; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
gone() { ! alive "$1"; }
spawn() { TMUX_PANE=%0 "$B/tmux-spawn" claude --from main "$@" </dev/null >/dev/null; }
ready() {
  local i
  for ((i=0; i<100; i++)); do
    # Requests/notices may scroll the startup marker off the visible screen.
    if tmux capture-pane -p -S - -t "$1" | grep -q "FAKE claude"; then
      return 0
    fi
    sleep .05
  done
  return 1
}
info() { tmux display-message -p -t "$1" "#{$2}"; }
record_for() { printf '%s/%s' "$(sessions_dir)" "$(info "$1" @agent_id)"; }
spawn --member --exact --name secondary
secondary="$(pane_of secondary)"
ready "$secondary" || { echo 'ABORT: member stub not ready'; exit 1; }
check 'default member is hidden' test "$(info "$secondary" session_name)" != work
check 'default member keeps owner' test "$(info "$secondary" @parent)" = %0
check 'member marker is local' test "$(tmux show -pqv -t "$secondary" @member)" = 1
check 'member recorded' grep -qx 'member=1' "$(record_for "$secondary")"
check 'member depth is one' grep -qx 'depth=1' "$(record_for "$secondary")"
# A top-level caller can give a member its own member; depth stays caller-based.
spawn --member --for secondary --split main --below --exact --name worker
worker="$(pane_of worker)"
ready "$worker" || { echo 'ABORT: worker stub not ready'; exit 1; }
check 'member supports split and for together' test "$(info "$worker" window_id)" = "$(info %0 window_id)"
check 'for member owned by secondary' test "$(info "$worker" @parent)" = "$secondary"
check 'for member only connected to owner' test "$(info "$worker" @peers)" = "$secondary"
check 'for member takes caller depth plus one' grep -qx 'depth=1' "$(record_for "$worker")"
# The positional argument is expanded by the child shell.
# shellcheck disable=SC2016
check 'member process receives depth one' bash -c 'tmux capture-pane -p -S - -t "$1" | grep -q DEPTH=1' _ "$worker"
# Helpers do not inherit membership, even when a window sets the option.
tmux set -w -t "$worker" @member 1
TMUX_AGENTS_DEPTH=1 "$B/tmux-spawn" claude --from worker --split "$worker" --exact --name helper </dev/null >/dev/null
helper="$(pane_of helper)"
ready "$helper" || { echo 'ABORT: helper stub not ready'; exit 1; }
check 'helper is ordinary' test "$(info "$helper" @member)" = 0
check 'split helper overrides inherited member marker' test "$(tmux show -pqv -t "$helper" @member)" = 0
check 'helper record has no member marker' test "$(record_get "$(info "$helper" @agent_id)" member)" = ''
check 'worker helper depth is two' grep -qx 'depth=2' "$(record_for "$helper")"
if TMUX_AGENTS_DEPTH=2 "$B/tmux-spawn" claude --from helper --name too-deep </dev/null >"$tmp/error" 2>&1; then
  check 'ordinary helper depth limit enforced' false
else
  check 'ordinary helper depth limit enforced' grep -q 'depth limit' "$tmp/error"
fi
tmux set -wu -t "$worker" @member
# --from must win over TMUX_PANE, and --for must not hide a restricted caller.
for caller in worker helper; do
  if TMUX_PANE=%0 TMUX_AGENTS_DEPTH=0 "$B/tmux-spawn" claude --from "$caller" --for main --member --name forbidden </dev/null >"$tmp/error" 2>&1; then
    check "$caller cannot spawn members" false
  else
    check "$caller cannot spawn members" grep -q "only a top-level agent can spawn members; $caller is a sub agent/member" "$tmp/error"
  fi
done
# A member remains restricted even after its parent is removed.
tmux set -pu -t "$worker" @parent
if TMUX_PANE="$worker" TMUX_AGENTS_DEPTH=0 "$B/tmux-spawn" claude --member --name forbidden </dev/null >"$tmp/error" 2>&1; then
  check 'unowned member caller refused' false
else
  check 'unowned member caller refused' grep -q 'only a top-level agent can spawn members; worker is a sub agent/member' "$tmp/error"
fi
tmux set -p -t "$worker" @parent "$secondary"
if TMUX_AGENTS_DEPTH=2 spawn --member --for secondary --name too-deep >"$tmp/error" 2>&1; then
  check 'member depth limit enforced' false
else
  check 'member depth limit enforced' grep -q 'depth limit' "$tmp/error"
fi
# Explicit main-level dismissal traverses members and their ordinary helpers.
secondary_id="$(info "$secondary" @agent_id)"
"$B/tmux-dismiss" --from main secondary >"$tmp/cascade"
for pane in "$secondary" "$worker" "$helper"; do check "cascade closes $pane" gone "$pane"; done
check 'closed record preserves member marker' test "$(record_get "$secondary_id" member)" = 1
"$B/tmux-spawn" --from main --resume-id "$secondary_id" </dev/null >/dev/null
secondary="$(pane_of secondary)"
ready "$secondary" || { echo 'ABORT: resumed stub not ready'; exit 1; }
check 'resume retains identity' test "$(info "$secondary" @agent_id)" = "$secondary_id"
check 'resume retains member' test "$(info "$secondary" @member)" = 1
# The positional argument is expanded by the child shell.
# shellcheck disable=SC2016
check 'resume retains depth in process' bash -c 'tmux capture-pane -p -S - -t "$1" | grep -q DEPTH=1' _ "$secondary"
check 'resume reconnects owner' test "$(info "$secondary" @parent)" = %0
check 'resume starts done' test "$(info "$secondary" @state)" = "done"
# An ordinary ancestor must not make a nested member eligible for --done.
spawn --exact --name ordinary
ordinary="$(pane_of ordinary)"
spawn --for ordinary --member --exact --name protected
protected="$(pane_of protected)"
TMUX_AGENTS_DEPTH=1 "$B/tmux-spawn" claude --from secondary --exact --name disposable </dev/null >/dev/null
disposable="$(pane_of disposable)"
for pane in "$ordinary" "$protected" "$disposable"; do
  ready "$pane" || { echo 'ABORT: cleanup stub not ready'; exit 1; }
  tmux set -p -t "$pane" @state "done"
done
# Run confirmation on a private test-server tty, never the caller's tty.
printf '#!/bin/sh\n"%s/tmux-dismiss" --from main --done >"%s/done-confirmed" 2>&1\necho $? >"%s/done-status"\nexec cat\n' "$B" "$tmp" "$tmp" >"$tmp/confirm"
confirm="$(tmux new-window -d -P -F '#{pane_id}' "/bin/sh '$tmp/confirm'")"
for ((i=0; i<100; i++)); do
  if [ -f "$tmp/done-confirmed" ] && grep -q '\[y/N\]' "$tmp/done-confirmed"; then break; fi
  sleep .05
done
check 'done offers ordinary helper for cleanup' grep -q "disposable ($disposable)" "$tmp/done-confirmed"
tmux send-keys -t "$confirm" y Enter
for ((i=0; i<100; i++)); do [ ! -f "$tmp/done-status" ] || break; sleep .05; done
check 'confirmed cleanup succeeds' test "$(cat "$tmp/done-status" 2>/dev/null)" = 0
check 'done explains skipped member' grep -q 'skipped secondary.*member' "$tmp/done-confirmed"
check 'done explains protected ancestor' grep -q 'skipped ordinary.*subtree contains members' "$tmp/done-confirmed"
check 'done preserves member' alive "$secondary"
check 'done preserves ordinary ancestor of member' alive "$ordinary"
check 'done preserves nested member' alive "$protected"
check 'done removes ordinary member helper' gone "$disposable"
# Even --keep-children never selects an ancestor containing members.
"$B/tmux-dismiss" --from main --done --keep-children >"$tmp/keep"
check 'keep-children also skips protected ancestor' grep -q 'skipped ordinary.*subtree contains members' "$tmp/keep"
check 'keep-children preserves ancestor' alive "$ordinary"
"$B/tmux-dismiss" --from main ordinary >/dev/null
check 'explicit ancestor dismissal closes protected member' gone "$protected"
[ "$fail" -ne 0 ] || echo "all $count checks passed"
exit "$fail"
