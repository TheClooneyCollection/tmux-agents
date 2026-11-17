#!/usr/bin/env bash
# Upgrade old ledger state on writer/install paths, never display/tool paths.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-state-migration-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-state-migration.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_ASK_ENTER_DELAY=0
mkdir -p "$tmp/home/bin"
tmux -L "$sock" -f /dev/null new-session -d -s test cat
tmux -L "$sock" has-session || exit 1
socket="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$socket,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
. "$B/lib.sh"
for n in 1 2 3 4 5 6; do tmux new-window -d cat; done
for n in 0 1 2 3 4 5 6; do
  tmux set -p -t "%$n" @agent "agent$n"
  tmux set -p -t "%$n" @tracked 1
  ensure_agent_id "%$n" >/dev/null
done
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=1; fi; }
opt() { tmux show -pqv -t "$1" "@$2"; }
seed() {
  tmux set -su @tmux_agents_state_version
  agent_start_work %0 working 100
  tmux set -p -t %0 @activity 'waiting for a worker'
  tmux set -p -t %1 @parent %0
  agent_start_work %1 working 100
  tmux set -p -t %1 @activity 'waiting for a peer'
  agent_start_work %6 working 100
  tmux set -p -t %6 @activity 'real work'
  agent_set_state %2 needs_you
  agent_set_state %3 needs_you
  tmux set -p -t %3 @explicit_needs_you 1
  agent_set_state %4 needs_you
  tmux set -p -t %4 @perm_since 100
  agent_set_state %5 needs_you
  tmux set -p -t %5 @asking 1
  for key in awaiting waiting_on request_local_work request_local_done request_notify_digest; do
    tmux set -p -t %0 "@$key" stale
  done
  ledger="$(sessions_dir)"; ledger="${ledger%/sessions}/requests"
  mkdir -p "$ledger/contexts" "$(messages_dir)"
  printf old >"$ledger/contexts/old"
  printf retained >"$(messages_dir)/r0123456789ab.txt"
}
seed
"$B/tmux-agent-report" --pane %3 --tool-end </dev/null
check 'tool hook does not migrate server' test -z "$(tmux show -sqv @tmux_agents_state_version)"
check 'tool hook leaves ledger directory' test -d "$ledger"
"$B/tmux-agents" --list >/dev/null
"$B/tmux-agents" --chip >/dev/null
check 'list/chip do not migrate server' test -z "$(tmux show -sqv @tmux_agents_state_version)"
"$B/tmux-agent-report" --from agent3 --needs-you 'explicit question'
check 'report migrates once' test "$(tmux show -sqv @tmux_agents_state_version)" = 1
check 'waiting top-level becomes idle' test "$(opt %0 state)" = idle
check 'waiting child becomes done' test "$(opt %1 state)" = "done"
check 'waiting activity is removed' test -z "$(opt %0 activity)$(opt %1 activity)"
check 'waiting turn is counted' test "$(opt %0 turns)" = 1
check 'ordinary work is preserved' test "$(opt %6 state)" = working
check 'ledger-only attention settles' test "$(opt %2 state)" = idle
check 'explicit attention remains' test "$(opt %3 state)" = needs_you
check 'permission attention remains' test "$(opt %4 state)" = needs_you
check 'question attention remains' test "$(opt %5 state)" = needs_you
for key in awaiting waiting_on request_local_work request_local_done request_notify_digest; do
  check "old $key removed" test -z "$(opt %0 "$key")"
done
check 'ledger is deleted' test ! -e "$ledger"
check 'retained messages survive' test -f "$(messages_dir)/r0123456789ab.txt"
agent_set_state %0 working
tmux set -p -t %0 @activity 'waiting for new text'
migrate_turn_state
check 'migration does not repeat on current server' test "$(opt %0 state)" = working
# Installer only operates on this fixture home and this private server.
seed
ln -s "$B/tmux-request-state" "$tmp/home/bin/tmux-request-state"
HOME="$tmp/home" BIN_DIR="$tmp/home/bin" TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$here/install.sh" --home "$tmp/home" >"$tmp/install.log" </dev/null
check 'sandbox installer leaves connected server alone' test -z "$(tmux show -sqv @tmux_agents_state_version)"
check 'sandbox installer preserves ledger' test -e "$ledger"
check 'installer links turn helpers' test -f "$tmp/home/bin/turn-state.sh"
check 'installer removes retired command link' test ! -L "$tmp/home/bin/tmux-request-state"
# Outside tmux, route the default-server probe to this private server using a
# wrapper. No command here can fall back to the user's real default server.
real_tmux="$(command -v tmux)"
mkdir "$tmp/wrapper"
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$real_tmux" "$socket" >"$tmp/wrapper/tmux"
chmod +x "$tmp/wrapper/tmux"
tmux set -su @tmux_agents_state_version
mkdir -p "$XDG_STATE_HOME/tmux-agents/default/requests"
env -i PATH="$tmp/wrapper:$PATH" HOME="$tmp/home" BIN_DIR="$tmp/home/bin" XDG_STATE_HOME="$XDG_STATE_HOME" TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$here/install.sh" --force >"$tmp/install-outside.log" </dev/null
check 'outside installer migrates its default server' test "$(tmux show -sqv @tmux_agents_state_version)" = 1
check 'outside installer deletes only its ledger' test ! -e "$XDG_STATE_HOME/tmux-agents/default/requests"
[ "$fail" -eq 0 ] && echo 'all passed'
exit "$fail"
