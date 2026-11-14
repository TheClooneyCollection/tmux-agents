#!/usr/bin/env bash
# Resume a closed child inside a verified shell pane and restore its ownership.
# shellcheck disable=SC2016,SC2329
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-resume-here-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-resume-here.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/project"
cat >"$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'STUB READY %s\n' "$*"
printf '%s\0' "$@" >"$RESUME_HERE_LOG/$TMUX_PANE.args"
while IFS= read -r line; do [ "$line" != STOP ] || exit 9; done
STUB
chmod +x "$tmp/bin/claude"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" RESUME_HERE_LOG="$tmp"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 50 -c "$tmp/project" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
. "$here/tests/helpers/cleanup.sh"
trap cleanup EXIT
tmux set-option -g default-shell /bin/sh
. "$B/lib.sh"
tmux set-option -p -t %0 @agent main
tmux set-option -p -t %0 @tracked 1
parent_id="$(ensure_agent_id %0)"
fail=0 count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
info() { tmux display-message -p -t "$1" "#{$2}"; }
# shellcheck disable=SC2329
wait_for() { local i; for ((i=0;i<160;i++)); do if "$@"; then return 0; fi; sleep .05; done; return 1; }
# shellcheck disable=SC2329
ready() { tmux capture-pane -pJ -S - -t "$1" | grep -Fq "conversation-$2"; }
# shellcheck disable=SC2329
option_equals() { [ "$(info "$1" "$2")" = "$3" ]; }
# shellcheck disable=SC2329
pane_runs_cat() { [ "$(info "$1" pane_current_command)" = cat ]; }
resume_here() {
  tmux send-keys -t "$1" -l "$B/tmux-spawn --resume-id $2 --here"
  tmux send-keys -t "$1" Enter
  wait_for ready "$1" "$2"
}
resume_record() {
  local id="$1" name="$2" parent="$3" member="${4:-0}"
  record_set "$id" name "$name"
  record_set "$id" kind claude
  record_set "$id" id "conversation-$id"
  record_set "$id" dir "$tmp/project"
  record_set "$id" parent "$parent"
  record_set "$id" parent_name "$(agent_name_by_id "$parent" 2>/dev/null || true)"
  record_set "$id" depth 1
  record_set "$id" member "$member"
  record_set "$id" closed "$(date +%s)"
}
# shellcheck disable=SC2329
reject_here() {
  if TMUX_PANE="$1" "$B/tmux-spawn" --resume-id "$target_id" --here </dev/null >"$tmp/error" 2>&1; then return 1; fi
  return 0
}
target_id=a000000000101 request_id=r000000000101
resume_record "$target_id" resume-child "$parent_id" 1
request_state create "$request_id" "$parent_id" "$target_id"
shell_pane="$(tmux new-window -d -P -F '#{pane_id}' -n resume-shell -c "$tmp/project" /bin/sh)"
check 'fixture is an interactive plain shell' verify_resume_shell "$shell_pane"
check 'tracked agent pane is rejected before mutation' reject_here %0
check 'tracked agent identity is unchanged' test "$(info %0 @agent_id)" = "$parent_id"
cat_pane="$(tmux new-window -d -P -F '#{pane_id}' -n non-shell -c "$tmp/project" cat)"
check 'non-shell fixture has started cat' wait_for pane_runs_cat "$cat_pane"
cat_before="$(tmux show-options -pq -t "$cat_pane")"
check 'non-shell process pane is rejected' reject_here "$cat_pane"
check 'non-shell rejection leaves pane options unchanged' test "$(tmux show-options -pq -t "$cat_pane")" = "$cat_before"
# A marked shell with a non-shell process is still refused.
tmux set-option -p -t "$cat_pane" @shell 1
check 'shell marker does not bless a non-shell process' reject_here "$cat_pane"
check 'marked non-shell rejection preserves marker' test "$(info "$cat_pane" @shell)" = 1
tmux set-option -pu -t "$cat_pane" @shell
check '--here without resume is rejected' bash -c '! TMUX_PANE="$1" "$2/tmux-spawn" --here </dev/null >/dev/null 2>&1' _ "$shell_pane" "$B"
check '--from is rejected with --here' bash -c '! TMUX_PANE="$1" "$2/tmux-spawn" --resume-id "$3" --here --from main </dev/null >/dev/null 2>&1' _ "$shell_pane" "$B" "$target_id"
check '--split is rejected with --here' bash -c '! TMUX_PANE="$1" "$2/tmux-spawn" --resume-id "$3" --here --split main </dev/null >/dev/null 2>&1' _ "$shell_pane" "$B" "$target_id"
check 'task text is rejected with --here' bash -c '! TMUX_PANE="$1" "$2/tmux-spawn" --resume-id "$3" --here extra </dev/null >/dev/null 2>&1' _ "$shell_pane" "$B" "$target_id"
check '--here reuses the current pane' resume_here "$shell_pane" "$target_id"
check 'restores stable agent identity' test "$(info "$shell_pane" @agent_id)" = "$target_id"
check 'restores parent connection' test "$(info "$shell_pane" @parent)" = %0
check 'restores member flag' test "$(info "$shell_pane" @member)" = 1
check 'clears closed record marker' test -z "$(record_get "$target_id" closed)"
check 'conversation argument is restored' python3 - "$tmp/$shell_pane.args" "$target_id" <<'PY'
import sys
args = open(sys.argv[1], 'rb').read().split(b'\0')[:-1]
assert args[-2:] == [b'--resume', ('conversation-' + sys.argv[2]).encode()], args
PY
check 'pending request remains attached to same identity' test "$(request_state incoming "$shell_pane")" = "$request_id"
check 'pending request restores working state' test "$(info "$shell_pane" @state)" = working
tmux send-keys -t "$shell_pane" STOP Enter
check 'shell regains prompt after resumed agent exits' wait_for option_equals "$shell_pane" @resume_shell 1
check 'exit hint includes in-place resume' bash -c 'tmux capture-pane -pJ -S - -t "$1" | grep -Fq "$2"' _ "$shell_pane" "tmux-spawn --resume-id $target_id --here"
check 'returned pane has no agent identity' test -z "$(info "$shell_pane" @agent_id)"

# A missing original owner stays unowned instead of attaching to the shell.
target_id=a000000000102
dead_parent_id="$(new_agent_id)"
resume_record "$target_id" orphan-child "$dead_parent_id" 0
check 'orphan resumes in the existing shell' resume_here "$shell_pane" "$target_id"
check 'missing owner is not replaced by the shell' test -z "$(info "$shell_pane" @parent)"
check 'missing owner stays absent from record' test -z "$(record_get "$target_id" parent)"
tmux send-keys -t "$shell_pane" STOP Enter
check 'orphan resume returns to shell' wait_for option_equals "$shell_pane" @resume_shell 1

# Keep the existing name suffix behavior when a live pane already owns it.
target_id=a000000000103
resume_record "$target_id" orphan-child "$(new_agent_id)" 0
clash_pane="$(tmux new-window -d -P -F '#{pane_id}' -n name-clash -c "$tmp/project" cat)"
tmux set-option -p -t "$clash_pane" @agent orphan-child
check 'name clash resumes with the existing suffix' resume_here "$shell_pane" "$target_id"
check 'suffixed name is recorded' test "$(record_get "$target_id" name)" = orphan-child-2
tmux send-keys -t "$shell_pane" STOP Enter
check 'name-clash resume returns to shell' wait_for option_equals "$shell_pane" @resume_shell 1

# Existing member shell panes recover their shell marker and display name.
target_id=a000000000104
resume_record "$target_id" marked-child "$parent_id" 0
tmux set-option -p -t "$shell_pane" @shell 1
tmux set-option -p -t "$shell_pane" @agent shell-helper
check 'marked shell pane resumes in place' resume_here "$shell_pane" "$target_id"
check 'marked shell enters tracked agent state' wait_for option_equals "$shell_pane" @tracked 1
check 'marked shell is temporarily an agent' test "$(info "$shell_pane" @shell)" != 1
tmux send-keys -t "$shell_pane" STOP Enter
check 'marked shell pane returns to shell state' wait_for option_equals "$shell_pane" @shell 1
check 'marked shell display name is restored' wait_for option_equals "$shell_pane" @agent shell-helper

printf '%s checks; failures=%s\n' "$count" "$fail"
exit "$fail"
