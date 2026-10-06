#!/usr/bin/env bash
# Named-pane takeover requires its own stdin tty and preserves connections.
# Child-shell commands intentionally contain unexpanded dollars.
# shellcheck disable=SC2016
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-start-takeover-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-start-takeover.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  cat > "$tmp/bin/$a" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\n' ready > "$TEST_LOG/$TMUX_PANE.ready"
exec cat
STUB
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH FROM_PANE
unset TMUX_AGENTS_NAME_FORMAT TMUX_START_NAME_EXACT TMUX_START_CHAIN_WORK
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile"
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TEST_LOG="$tmp"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 70 -c "$tmp" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
Q="/tmp/tmux-agents-$(id -u)/queue/$sock"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
. "$B/lib.sh"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
info() { tmux display -p -t "$1" "#{@$2}"; }
wait_file() { local i; for ((i=0;i<200;i++)); do [ ! -s "$1" ] || return 0; sleep .05; done; return 1; }
# Snapshot every pane option and every state file, including migration markers.
snapshot() {
  python3 - "$XDG_STATE_HOME" "$Q" <<'PY'
import pathlib, subprocess, sys
panes=subprocess.check_output(['tmux','list-panes','-a','-F','#{pane_id}']).splitlines()
for pane in sorted(panes):
    print(pane, subprocess.check_output(['tmux','show-options','-p','-t',pane.decode()]))
for path in sys.argv[1:]:
    root=pathlib.Path(path)
    for p in sorted(root.rglob('*')):
        print(str(p), p.read_bytes() if p.is_file() else 'directory')
PY
}
quote_command() { python3 - "$@" <<'PY'
import shlex,sys
print(shlex.join(sys.argv[1:]))
PY
}
# Use an actual interactive shell, first running a manually launched agent.
pane="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp")"
tmux send-keys -t "$pane" -l "$(quote_command "$tmp/bin/codex")"
tmux send-keys -t "$pane" Enter
wait_file "$tmp/$pane.ready"
check 'direct stub started' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE codex"' _ "$pane"
tmux send-keys -t "$pane" C-d
# Seed a legacy named pane without an ID, before migration has ever run.
tmux set -p -t "$pane" @agent stale-label
tmux set -p -t "$pane" @activity stale
snapshot > "$tmp/before"
if TMUX_PANE="$pane" "$B/tmux-agents-start" codex --name "bad name" --exact </dev/null > "$tmp/error" 2>&1; then
  echo 'FAIL no-tty launch accepted'; fail=1
fi
snapshot > "$tmp/after"
check 'no tty rejects without any state or migration changes' cmp "$tmp/before" "$tmp/after"
check 'refusal names the pane and explains own terminal' grep -q "pane 'stale-label'.*not running from its own terminal" "$tmp/error"
check 'refusal explains shell or fresh pane recovery' grep -q 'quit the agent.*shell.*fresh pane' "$tmp/error"
# A real tty belonging to another pane must also fail before migration.
other="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp")"
snapshot > "$tmp/before"
cmd="$(quote_command env "TMUX_PANE=$pane" "$B/tmux-agents-start" codex)"
error="$(quote_command "$tmp/different-error")"
status="$(quote_command "$tmp/different-status")"
tmux send-keys -t "$other" -l "$cmd >$error 2>&1; echo \$? >$status"
tmux send-keys -t "$other" Enter
wait_file "$tmp/different-status"
snapshot > "$tmp/after"
check 'different tty returns failure' test "$(cat "$tmp/different-status")" != 0
check 'different tty preserves all state' cmp "$tmp/before" "$tmp/after"
check 'different tty explains refusal' grep -q 'not running from its own terminal' "$tmp/different-error"
# Rejections from the pane's own tty must not migrate even legacy/no-ID state.
refused_start() {
  local label="$1" pattern="$2" cmd error status; shift 2
  rm -f "$tmp/refusal-status"
  snapshot > "$tmp/before"
  cmd="$(quote_command "$B/tmux-agents-start" codex "$@")"
  error="$(quote_command "$tmp/refusal-error")"
  status="$(quote_command "$tmp/refusal-status")"
  tmux send-keys -t "$pane" -l "$cmd >$error 2>&1; echo \$? >$status"
  tmux send-keys -t "$pane" Enter
  wait_file "$tmp/refusal-status"
  snapshot > "$tmp/after"
  check "$label returns failure" test "$(cat "$tmp/refusal-status")" != 0
  check "$label diagnostic" grep -q -- "$pattern" "$tmp/refusal-error"
  check "$label leaves state byte-identical" cmp "$tmp/before" "$tmp/after"
}
tmux set -p -t %0 @agent peer-label
refused_start 'legacy collision' "name 'peer-label' is already used by pane" --name peer-label --exact
refused_start 'legacy invalid exact name' "invalid name 'bad name'" --name 'bad name' --exact
refused_start 'exact without name' '--exact requires --name' --exact
check 'legacy refusals allocate no identity' test -z "$(pane_agent_id "$pane")"
# Establish an old identity, a connected child and stale state of every kind.
set_name "$pane" stale-label
set_name %0 peer-label
old_id="$(pane_agent_id "$pane")"
record_set "$old_id" name stale-label
record_set "$old_id" kind codex
record_set "$old_id" id old-thread
add_peer "$pane" %0
add_peer %0 "$pane"
tmux set -p -t %0 @parent "$pane"
for key in tracked member state_since worked last_turn turns turn_start turn_work turn_active started perm_since msg_waiting_since work_closed work_restored attention_since; do
  tmux set -p -t "$pane" "@$key" 1
done
for key in parent closed activity awaiting waiting_on codex_thread; do
  tmux set -p -t "$pane" "@$key" stale
done
tmux set -p -t "$pane" @state needs_you
refresh_labels
old_peers="$(info "$pane" peers)" old_labels="$(info "$pane" peer_names)"
peer_peers="$(info %0 peers)"
# Keep peer notices queued, so their body and stable identity can be checked.
tmux copy-mode -t %0
peer_id="$(pane_agent_id %0)"
tmux set -p -t %0 @awaiting "$old_id"
tmux set -p -t %0 @closed "retained-id $old_id"
mkdir -p "$Q"
printf 'from_id=%s\nto_id=%s\nfrom_name=stale-label\nto_name=peer-label\nkind=reply\n' "$old_id" "$peer_id" > "$Q/retained.meta"
printf 'retained identity body\n' > "$Q/retained.undelivered"
cp "$Q/retained.meta" "$tmp/retained-before"
refused_start 'identified collision' "name 'peer-label' is already used by pane" --name peer-label --exact
refused_start 'identified invalid exact name' "invalid name 'bad name'" --name 'bad name' --exact
# Called indirectly by check.
# shellcheck disable=SC2329
notice_matches() {
  local f
  for f in "$Q"/*.msg "$Q"/*.undelivered; do
    [ -f "$f" ] || continue
    if grep -qF "$2" "$f" && grep -qx 'from_name=tmux-rename' "${f%.*}.meta" &&
        grep -qx "to_id=$1" "${f%.*}.meta"; then return 0; fi
  done
  return 1
}
rm "$tmp/$pane.ready"
cmd="$(quote_command "$B/tmux-agents-start" codex --name renamed-label --exact)"
tmux send-keys -t "$pane" -l "$cmd; echo finished > $(quote_command "$tmp/finished")"
tmux send-keys -t "$pane" Enter
if ! wait_file "$tmp/$pane.ready"; then
  tmux capture-pane -p -t "$pane"
  echo 'FAIL own-terminal takeover did not launch'; exit 1
fi
new_id="$(pane_agent_id "$pane")"
check 'takeover uses requested renamed label' test "$(info "$pane" agent)" = renamed-label
check 'takeover assigns fresh ID' test "$new_id" != "$old_id"
check 'new ID is valid' valid_agent_id "$new_id"
check 'takeover is tracked and idle' test "$(info "$pane" tracked):$(info "$pane" state)" = 1:idle
check 'takeover starts with zero work' test "$(info "$pane" worked)" = 0
check 'takeover is not a member' test "$(info "$pane" member)" = 0
check 'takeover preserves peers and labels' test "$(info "$pane" peers):$(info "$pane" peer_names)" = "$old_peers:$old_labels"
check 'takeover preserves reverse peers and labels' test "$(info %0 peers):$(info %0 peer_names)" = "$peer_peers:renamed-label"
check 'takeover detaches old child parent link' test -z "$(info %0 parent)"
check 'old record follows rename before closing' test "$(record_get "$old_id" name)" = renamed-label
check 'peer awaiting link retains old identity' test "$(info %0 awaiting)" = "$old_id"
check 'saved queue identity metadata stays unchanged' cmp "$Q/retained.meta" "$tmp/retained-before"
check 'rename emits existing peer notice with identity metadata' notice_matches "$peer_id" 'stale-label is now renamed-label'
check 'old record closed' test -n "$(record_get "$old_id" closed)"
check 'old conversation preserved' test "$(record_get "$old_id" id)" = old-thread
check 'peer receives old identity closure' test "$(info %0 closed)" = "retained-id $old_id"
check 'new record describes preserved name and launcher' test "$(record_get "$new_id" name):$(record_get "$new_id" launcher)" = renamed-label:1
check 'new record is open' test -z "$(record_get "$new_id" closed)"
for key in parent closed last_turn turn_start turn_work turn_active perm_since msg_waiting_since work_closed work_restored activity awaiting waiting_on attention_since codex_thread; do
  check "takeover clears @$key" test -z "$(info "$pane" "$key")"
done
# Exiting the new child still does ordinary disconnect-and-clear cleanup.
tmux send-keys -t "$pane" C-d
wait_file "$tmp/finished"
check 'normal exit clears name identity and peers' test -z "$(info "$pane" agent)$(info "$pane" agent_id)$(info "$pane" peers)$(info "$pane" peer_names)"
check 'normal exit disconnects reverse peers' test -z "$(info %0 peers)"
check 'normal exit closes new record' test -n "$(record_get "$new_id" closed)"
# More launches exercise formatting and no-op paths on the same real tty.
# Check identity-specific notices rather than unrelated queue file counts.
# shellcheck disable=SC2329
no_rename_notice() {
  local f
  for f in "$Q"/*.meta; do
    [ -f "$f" ] || continue
    if grep -qx 'from_name=tmux-rename' "$f" && grep -qx "to_id=$1" "$f"; then return 1; fi
  done
  ! tmux capture-pane -p -t "$pane" | grep -qF "you are now $2; pass --from $2 from now on"
}
takeover_case() {
  local label="$1" old="$2" expected="$3" kind="$4" old_identity; shift 4
  set_name "$pane" "$old"
  old_identity="$(pane_agent_id "$pane")"
  record_set "$old_identity" name "$old"
  rm -f "$tmp/$pane.ready" "$tmp/case-finished"
  tmux send-keys -t "$pane" -l "$(quote_command "$B/tmux-agents-start" "$kind" "$@"); echo done > $(quote_command "$tmp/case-finished")"
  tmux send-keys -t "$pane" Enter
  wait_file "$tmp/$pane.ready"
  check "$label label" test "$(pane_name "$pane")" = "$expected"
  check "$label old record label" test "$(record_get "$old_identity" name)" = "$expected"
  check "$label replaces identity" test "$(pane_agent_id "$pane")" != "$old_identity"
  if [ "$old" = "$expected" ]; then
    check "$label emits no rename notices" no_rename_notice "$old_identity" "$old"
  fi
  tmux send-keys -t "$pane" C-d
  wait_file "$tmp/case-finished"
}
takeover_case 'no supplied name' unchanged unchanged codex
takeover_case 'same raw name' unchanged unchanged codex --name unchanged
prefix="$(format_given_name codex "$tmp" task 0)"
takeover_case 'same formatted name' "$prefix" "$prefix" codex --name task
takeover_case 'profile uses incoming Codex prefix' old-claude "$prefix" extra --name task
claude_prefix="$(format_given_name claude "$tmp" Task-Name 0)"
takeover_case 'incoming Claude prefix and sanitization' old-codex "$claude_prefix" claude --name 'Task Name'
takeover_case 'already prefixed name' old-codex "$prefix" codex --name "$prefix"
tmux set -g @tmux_agents_name_format exact
takeover_case 'exact option' old-codex option-name codex --name option-name
tmux set -g @tmux_agents_name_format prefixed
takeover_case 'exact flag' old-codex exact-name codex --exact --name exact-name
# The same shell is now fresh: ordinary unnamed launch remains supported.
rm "$tmp/$pane.ready"
tmux send-keys -t "$pane" -l "$(quote_command "$B/tmux-agents-start" claude --name fresh-label --exact)"
tmux send-keys -t "$pane" Enter
wait_file "$tmp/$pane.ready"
check 'fresh unnamed pane launches normally' test "$(info "$pane" agent):$(info "$pane" tracked):$(info "$pane" state)" = fresh-label:1:idle
check 'fresh Claude stub marker' bash -c 'tmux capture-pane -p -t "$1" | grep -q "FAKE claude"' _ "$pane"
exit "$fail"
