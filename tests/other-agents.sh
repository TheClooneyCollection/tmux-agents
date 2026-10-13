#!/usr/bin/env bash
# shellcheck disable=SC2329
# Arbitrary external agents: validation, adapter priority and safe bare launch.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-other-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-other.XXXXXX")"
mkdir -p "$tmp/bin"
for command in claude codex other-agent collision; do
  cat > "$tmp/bin/$command" <<'STUB'
#!/usr/bin/env bash
python3 - "$TEST_LOG/$TMUX_PANE.json" "${0##*/}" "$@" <<'PY'
import json, os, sys
with open(sys.argv[1], 'w') as f:
    json.dump(dict(command=sys.argv[2], args=sys.argv[3:],
                   home=os.getenv('CODEX_HOME'), pin=os.getenv('TMUX_AGENTS_PINNED'),
                   claude=os.getenv('CLAUDECODE')), f)
PY
printf 'FAKE %s\n' "${0##*/}"
printf 'ready\n' > "$TEST_LOG/$TMUX_PANE.ready"
exec cat
STUB
  chmod +x "$tmp/bin/$command"
done
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/not-executable"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
unset TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER
export PATH="$tmp/bin:$PATH" TMUX_SPAWN_BIN="$tmp/bin" TEST_LOG="$tmp"
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_CODEX_HOMES="collision=$tmp/profile"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" cat
tmux -L "$sock" has-session
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
# The caller may have a newer PATH than the server. Do not let the test hook
# hide a missing caller-to-child PATH handoff for the generic executable.
mkdir "$tmp/caller-bin"
mv "$tmp/bin/other-agent" "$tmp/caller-bin/other-agent"
export PATH="$tmp/caller-bin:$PATH"
. "$B/lib.sh"
resolve_codex_homes codex_homes
set_name %0 main
ensure_agent_id %0 >/dev/null
export TMUX_PANE=%0 TMUX_AGENTS_PINNED=1
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok $label"; else echo "FAIL $label"; fail=1; fi; }
wait_ready() { local i; for ((i=0;i<100;i++)); do [ ! -s "$tmp/$1.ready" ] || return 0; sleep .05; done; return 1; }
count() { tmux list-panes -a -F '#{pane_id}' | wc -l | tr -d ' '; }
reject() {
  local before
  before="$(count)"
  if "$@" >"$tmp/rejected" 2>&1; then return 1; fi
  [ -s "$tmp/rejected" ] && [ "$(count)" = "$before" ]
}
bare() {
  wait_ready "$1" || return 1
  [ "$(tmux display -p -t "$1" '#{@tracked}')" = 0 ] || return 1
  [ -z "$(tmux display -p -t "$1" '#{@turn_start}#{@worked}')" ] || return 1
  python3 - "$tmp/$1.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d['command']=='other-agent' and d['args']==[], d
assert d['pin'] is None and d['claude'] is None, d
PY
}
for role in main secondary worker; do
  check "query accepts $role without execution" test "$("$B/tmux-agents" chain-config "$role" "--$role" other-agent)" = other-agent
  for bad in missing-agent-xyz not-executable 'bad;command' /bin/cat; do
    check "reject $role $bad" reject "$B/tmux-agents" chain-config "$role" "--$role" "$bad"
    check "chain rejects $role $bad before opening window" reject "$B/tmux-agents" start chain "$tmp" "--$role" "$bad"
  done
  tmux set -g "@tmux_agents_chain_$role" other-agent
  check "option $role" test "$("$B/tmux-agents" chain-config "$role")" = other-agent
  tmux set -gu "@tmux_agents_chain_$role"
done
check 'env role' test "$(TMUX_AGENTS_CHAIN_WORKER=other-agent "$B/tmux-agents" chain-config worker)" = other-agent
check 'query never executes' test ! -f "$tmp/%0.ready"
for bad in missing-agent-xyz not-executable 'bad;command'; do
  check "start rejects $bad" reject "$B/tmux-agents" start "$bad"
  check "spawn rejects $bad" reject "$B/tmux-spawn" "$bad" --from main
done
pane="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "'$B/tmux-agents' start other-agent --name direct --exact")"
check 'start bare and untracked' bare "$pane"
out="$("$B/tmux-spawn" other-agent --from main --name review 'Do not pass this task as argv')"
pane="$(find_pane "other-agent-${tmp##*/}-review")"
check 'spawn bare and untracked' bare "$pane"
check 'spawn reports unsent task' test "${out#*task was not sent:}" != "$out"
aid="$(pane_agent_id "$pane")"
"$B/tmux-dismiss" --from main "other-agent-${tmp##*/}-review"
check 'unknown resume rejected without window' reject "$B/tmux-spawn" --resume-id "$aid" --from main
check 'resume explains adapter limit' grep -q 'no conversation adapter' "$tmp/rejected"
"$B/tmux-agents" start chain "$tmp" --main other-agent --secondary other-agent --worker other-agent
pane="$(tmux list-panes -t work: -F '#{pane_id}')"
check 'chain has no injected prompt or tracking' bare "$pane"
out="$("$B/tmux-spawn" other-agent --from main --split main --name split 'Manual brief')"
pane="$(find_pane "other-agent-${tmp##*/}-split")"
check 'split forwards caller PATH and stays bare' bare "$pane"
owner="$(find_pane direct)"
add_peer %0 "$owner"
add_peer "$owner" %0
out="$("$B/tmux-spawn" other-agent --from main --for direct --name owned 'Manual owner brief')"
pane="$(find_pane "other-agent-${tmp##*/}-owned")"
check 'owned helper remains bare' bare "$pane"
check 'owned helper reports manual first task' test "${out#*task was not sent to it.}" != "$out"
check 'profile query retains profile label' test "$("$B/tmux-agents" chain-config worker --worker collision)" = collision
pane="$(tmux new-window -d -P -F '#{pane_id}' -c "$tmp" "'$B/tmux-agents' start collision --name collision-direct --exact")"
wait_ready "$pane"
check 'start prefers profile over same-named executable' python3 - "$tmp/$pane.json" "$tmp/profile" <<'PYPROFILE'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['command']=='codex' and d['home']==sys.argv[2],d
PYPROFILE
"$B/tmux-agents" start chain "$tmp" --main collision --secondary other-agent --worker collision
pane="$(tmux list-panes -t work: -F '#{pane_id}')"
wait_ready "$pane"
check 'chain prefers profile and retains its prompt' python3 - "$tmp/$pane.json" <<'PYPROFILE'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['command']=='codex' and 'start the chain.' in d['args'][-1],d
PYPROFILE
check 'profile naming wins over executable' test "$(name_kind_for collision)" = codex
out="$("$B/tmux-spawn" collision --from main --name profile)"
pane="$(find_pane "codex-${tmp##*/}-profile")"
wait_ready "$pane"
check 'profile stays tracked' test "$(tmux display -p -t "$pane" '#{@tracked}')" = 1
check 'profile adapter wins over PATH command' python3 - "$tmp/$pane.json" "$tmp/profile" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['command']=='codex' and d['home']==sys.argv[2],d
assert '-c' in d['args'],d
PY
exit "$fail"
