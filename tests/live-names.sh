#!/usr/bin/env bash
# Public commands still address live labels after legacy migration and rename.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
state="$(mktemp -d "${TMPDIR:-/tmp}/live-names.XXXXXX")"
sock="live-names-$$"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$state/state" TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_IDLE_SECS=0
queue="/tmp/tmux-agents-$(id -u)/queue/$sock"
cleanup() { tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$state" "$queue"; }
trap cleanup EXIT
mkdir -p "$state/project"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 140 -y 40 'exec cat'
tmux -L "$sock" has-session
socket="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket' >&2; exit 1 ;; esac
export TMUX="$socket,1,0" TMUX_PANE=%0
tmux set-option -g default-shell /bin/sh
tmux split-window -d -h -t %0 -c "$state/project" 'exec cat'
tmux set -p -t %0 @agent caller
tmux set -p -t %1 @agent codex-project-original
tmux set -p -t %1 @parent %0
. "$B/lib.sh"
records="$(sessions_dir)"
mkdir -p "$records" "$state/queue"
printf 'kind=claude\nid=caller-conversation\n' > "$records/caller"
printf 'kind=codex\nid=child-conversation\nparent=caller\ndir=%s\n' "$state/project" > "$records/codex-project-original"
ensure_agent_ids "$state/queue"
checks=0
check() { local title="$1"; shift; "$@" || { echo "FAIL $title"; exit 1; }; checks=$((checks + 1)); echo "ok $title"; }
wait_text() {
  local i=0
  while [ "$i" -lt 100 ]; do
    if "$B/tmux-peek" --from caller "$1" 200 | grep -q "$2"; then return 0; fi
    sleep 0.05; i=$((i + 1))
  done
  return 1
}
child_id="$(pane_agent_id %1)"
check 'migration assigned hidden ID' valid_agent_id "$child_id"
check 'migration preserved conversation' test "$(record_get "$child_id" id)" = child-conversation
check 'connect by migrated name' "$B/tmux-connect" --from caller codex-project-original
check 'message by migrated name' "$B/tmux-ask" --from caller codex-project-original migrated-name-message
check 'peek by migrated name reads delivered body' wait_text codex-project-original migrated-name-message
check 'connect by agent kind' "$B/tmux-connect" --from caller codex
check 'connect by kind and project' "$B/tmux-connect" --from caller codex@project
check 'connect by pane ID' "$B/tmux-connect" --from caller %1
check 'rename by live name' "$B/tmux-rename" --from caller codex-project-original codex-project-renamed --exact
check 'rename preserves hidden identity' test "$(pane_agent_id %1)" = "$child_id"
check 'connect by renamed label' "$B/tmux-connect" --from caller codex-project-renamed
check 'message by renamed label' "$B/tmux-ask" --from caller codex-project-renamed renamed-label-message
check 'peek by renamed label reads delivered body' wait_text codex-project-renamed renamed-label-message
check 'kind and project still match renamed label' "$B/tmux-connect" --from caller codex@project
if "$B/tmux-ask" --from caller codex-project-original stale-label 2>/dev/null; then echo 'FAIL stale label resolved'; exit 1; fi
check 'default peers displays live label' grep -q codex-project-renamed < <("$B/tmux-peers" --from caller)
check 'explicit peers IDs exposes identity' grep -q "$child_id" < <("$B/tmux-peers" --from caller --ids)
check 'dismiss accepts renamed label' "$B/tmux-dismiss" --from caller codex-project-renamed
check 'closed record retains original conversation' test "$(record_get "$child_id" id)" = child-conversation
check 'closed record retains current label' test "$(record_get "$child_id" name)" = codex-project-renamed
check 'closed timestamp is recorded' test -n "$(record_get "$child_id" closed)"
printf '%s checks passed\n' "$checks"
