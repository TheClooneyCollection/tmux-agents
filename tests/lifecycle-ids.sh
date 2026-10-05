#!/usr/bin/env bash
# Stable identities across name reuse, rename, dismissal and reopening.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-lifecycle-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-spawn-names.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project"
for a in claude codex; do
  # Expanded by the child shell, Perl, or generated script, not this shell.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "STUB READY %s FORMAT=%%s HOME=%%s HOMES=%%s\\n" "${TMUX_AGENTS_NAME_FORMAT-unset}" "${CODEX_HOME-unset}" "${TMUX_AGENTS_CODEX_HOMES-unset}"\nexec cat\n' "$a" >"$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_NAME_FORMAT
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/codex-home"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 -c "$tmp/project" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# No personal shell startup files may run in spawned test panes.
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
fail=0 count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
spawn() { "$B/tmux-spawn" "$@" --from "${caller:-main}" </dev/null; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
reject() { if spawn "$@" >"$tmp/error" 2>&1; then return 1; else return 0; fi; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
ready() {
  local p="$1" kind="$2" i
  [ -n "$p" ] || return 1
  for ((i=0; i<100; i++)); do
    tmux capture-pane -p -J -t "$p" -S -100 >"$tmp/screen"
    if grep -q "STUB READY $kind " "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  return 1
}
expect_spawn() {
  local expected="$1" kind="$2"; shift 2
  spawn "$@" >"$tmp/spawn"
  check "prints $expected" grep -Fq " as $expected," "$tmp/spawn"
  spawned="$(pane_of "$expected")"
  check "$expected has the $kind stub" ready "$spawned" "$kind"
}
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
expect_spawn shared claude claude --exact --name shared
first_id="$(pane_agent_id "$spawned")"
first_sid="$(record_get "$first_id" id)"
caller=shared expect_spawn descendant claude claude --exact --name descendant
child_id="$(pane_agent_id "$spawned")"
"$B/tmux-dismiss" --from main shared >/dev/null
expect_spawn shared claude claude --exact --name shared
second_id="$(pane_agent_id "$spawned")"
check 'reused name gets a new ID' test "$first_id" != "$second_id"
check 'old conversation preserved' test "$(record_get "$first_id" id)" = "$first_sid"
check 'old child retains original parent ID' test "$(record_get "$child_id" parent)" = "$first_id"
# Reopening a child must not treat the reused parent label as its parent.
spawn --resume-id "$child_id" >/dev/null
check 'missing original parent falls back to caller' test "$(tmux show -pqv -t "$(pane_of descendant)" @parent)" = %0
"$B/tmux-dismiss" --from main descendant >/dev/null
spawn --resume shared >"$tmp/reopened"
check 'resume matches closed record despite live namesake' test "$(pane_agent_id "$(pane_of shared-2)")" = "$first_id"
check 'resumed record label updated to suffix' test "$(record_get "$first_id" name)" = shared-2
check 'resumed conversation unchanged' test "$(record_get "$first_id" id)" = "$first_sid"
check 'resumed stub ready' ready "$(pane_of shared-2)" claude
"$B/tmux-dismiss" --from main shared-2 >/dev/null
# Rename may reuse a closed label without changing either identity.
"$B/tmux-rename" --from main shared shared-2 --exact >/dev/null
check 'rename keeps live identity' test "$(pane_agent_id "$(pane_of shared-2)")" = "$second_id"
check 'rename preserves closed conversation' test "$(record_get "$first_id" id)" = "$first_sid"
"$B/tmux-dismiss" --from main shared-2 >/dev/null
check 'two closed namesakes refuse ambiguous resume' reject --resume shared-2
check 'ambiguous result lists first ID' grep -q "$first_id" "$tmp/error"
check 'ambiguous result lists second ID' grep -q "$second_id" "$tmp/error"
spawn --list-closed >"$tmp/closed-list"
check 'list includes first identity' grep -q "$first_id" "$tmp/closed-list"
check 'list includes second identity' grep -q "$second_id" "$tmp/closed-list"
spawn --resume-id "$second_id" >/dev/null
check 'resume-id chooses second exactly' test "$(pane_agent_id "$(pane_of shared-2)")" = "$second_id"
spawn --resume-id "$first_id" >/dev/null
check 'resume-id keeps ID with live collision' test "$(pane_agent_id "$(pane_of shared-2-2)")" = "$first_id"
check 'live identity cannot reopen twice' reject --resume-id "$first_id"
check 'resume and resume-id cannot combine' reject --resume shared-2 --resume-id "$first_id"
# Automatic names also become reusable without overwriting history.
spawn claude >/dev/null
auto_pane="$(pane_of claude-project-1)" auto_id="$(pane_agent_id "$auto_pane")"
auto_sid="$(record_get "$auto_id" id)"
check 'automatic stub ready' ready "$auto_pane" claude
"$B/tmux-dismiss" --from main claude-project-1 >/dev/null
spawn claude >/dev/null
check 'automatic name reused with fresh ID' test "$(pane_agent_id "$(pane_of claude-project-1)")" != "$auto_id"
check 'automatic old conversation retained' test "$(record_get "$auto_id" id)" = "$auto_sid"
# Restoring a live renamed parent uses its ID, not the stale saved label.
caller=shared-2 expect_spawn owned claude claude --exact --name owned
owned_id="$(pane_agent_id "$spawned")"
"$B/tmux-dismiss" --from main owned >/dev/null
"$B/tmux-rename" --from main shared-2 renamed-parent --exact >/dev/null
if "$B/tmux-spawn" --resume-id "$owned_id" --from missing-caller </dev/null >"$tmp/error" 2>&1; then
  check 'resume validates an explicit caller' false
else
  check 'resume validates an explicit caller' true
fi
spawn --resume-id "$owned_id" >/dev/null
check 'resume restores original live parent after rename' test "$(tmux show -pqv -t "$(pane_of owned)" @parent)" = "$(pane_of renamed-parent)"
check 'resume stores original parent ID' test "$(record_get "$owned_id" parent)" = "$second_id"
spawn codex --exact --name no-conversation >/dev/null
no_conversation_id="$(pane_agent_id "$(pane_of no-conversation)")"
check 'Codex stub ready' ready "$(pane_of no-conversation)" codex
"$B/tmux-dismiss" --from main no-conversation >/dev/null
spawn --list-closed >"$tmp/closed-list"
check 'list excludes live resumed identity' test "$(grep -c "$first_id" "$tmp/closed-list" || true)" = 0
check 'list excludes missing conversations' test "$(grep -c "$no_conversation_id" "$tmp/closed-list" || true)" = 0
[ "$fail" -ne 0 ] || echo "all $count checks passed"
exit "$fail"
