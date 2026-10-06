#!/usr/bin/env bash
# Sub-agent auto permissions: defaults, options, child env, members and resume.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-sub-auto-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-sub-auto.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project"
for kind in claude codex; do
  cat >"$tmp/bin/$kind" <<'STUB'
#!/bin/sh
auto=off resume=no previous=
for arg do
  case "$arg" in
    auto) [ "$previous" != --permission-mode ] || auto=on ;;
    'approvals_reviewer="auto_review"') [ "$previous" != -c ] || auto=on ;;
    resume|--resume) resume=yes ;;
  esac
  previous="$arg"
done
printf 'STUB READY %s AUTO=%s RESUME=%s ENV=%s\n' "${0##*/}" "$auto" "$resume" "${TMUX_AGENTS_SUB_AUTO-unset}"
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
info() { tmux display-message -p -t "$1" "#{$2}"; }
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
expect() {
  local name="$1" kind="$2" auto="$3" resume="${4:-no}"
  ready "$(pane_of "$name")" "$kind" || { echo "ABORT: $name stub not ready"; exit 1; }
  check "$name auto=$auto resume=$resume" grep -Fq "STUB READY $kind AUTO=$auto RESUME=$resume " "$tmp/screen"
}
for kind in claude codex; do
  tmux set -gu @tmux_agents_sub_auto
  spawn "$kind" --exact --name "$kind-default"
  expect "$kind-default" "$kind" on
  for value in on off; do
    tmux set -g @tmux_agents_sub_auto "$value"
    spawn "$kind" --exact --name "$kind-option-$value"
    expect "$kind-option-$value" "$kind" "$value"
    check 'tmux option does not become child env override' grep -Fq 'ENV=unset' "$tmp/screen"
    # A fresh helper invocation avoids reusing the sourced settings snapshot.
    args="$(TMUX_AGENTS_SUB_AUTO="$value" bash -c 'here="$1"; . "$here/lib.sh"; build_agent_command "$2" start; printf "%s\n" "${agent_command[@]}"' _ "$B" "$kind")"
    check "$kind start ignores $value" test "$(printf '%s\n' "$args" | grep -Ec -- '^(--permission-mode|approvals_reviewer=)' || true)" = 0
  done
  tmux set -g @tmux_agents_sub_auto on
  TMUX_AGENTS_SUB_AUTO=off spawn "$kind" --exact --name "$kind-env-off" --member
  expect "$kind-env-off" "$kind" off
  check 'explicit off reaches member child' grep -Fq 'ENV=off' "$tmp/screen"
  check 'member marker retained' test "$(info "$(pane_of "$kind-env-off")" @member)" = 1
  tmux set -g @tmux_agents_sub_auto off
  TMUX_AGENTS_SUB_AUTO=on spawn "$kind" --exact --name "$kind-env-on" --split main --below --size 20%
  expect "$kind-env-on" "$kind" on
  check 'explicit on reaches split child' grep -Fq 'ENV=on' "$tmp/screen"
  "$B/tmux-dismiss" --from main "$kind-env-on" >/dev/null
  # Codex normally records its conversation ID on the first turn-end hook.
  aid="$(pane_agent_id "$(pane_of "$kind-env-off")")"
  [ "$kind" != codex ] || record_set "$aid" id test-codex-conversation
  for value in on off; do
    "$B/tmux-dismiss" --from main "$kind-env-off" >/dev/null
    if [ "$value" = on ]; then tmux set -g @tmux_agents_sub_auto off
    else tmux set -g @tmux_agents_sub_auto on; fi
    TMUX_AGENTS_SUB_AUTO="$value" spawn --resume-id "$aid"
    expect "$kind-env-off" "$kind" "$value" yes
    check "resume env=$value reaches child" grep -Fq "ENV=$value" "$tmp/screen"
    check 'resume preserves membership' test "$(info "$(pane_of "$kind-env-off")" @member)" = 1
  done
done
[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
