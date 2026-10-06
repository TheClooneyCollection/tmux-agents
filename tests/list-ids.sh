#!/usr/bin/env bash
# Identity-keyed list ancestry, hidden picker keys, exact resume and peers IDs.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-list-ids.XXXXXX")"
sock="tmux-list-ids-$$"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_DEPTH TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/stubs" TMUX_ASK_ENTER_DELAY=0
mkdir -p "$tmp/stubs" "$tmp/ui"
for kind in claude codex; do
  printf '#!/bin/sh\nprintf "STUB READY %s %%s\\n" "$*"\nexec cat\n' "$kind" >"$tmp/stubs/$kind"
  chmod +x "$tmp/stubs/$kind"
done
tmux -L "$sock" -f /dev/null new-session -d -s work -x 200 -y 50 -c "$tmp" cat
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
other="$(tmux new-window -d -t work -c "$tmp" -P -F '#{pane_id}' cat)"
tmux set -p -t "$other" @agent duplicate
. "$B/lib.sh"
# A cold picker must reach fzf without synchronously running migration.
records="$(sessions_dir)"; mkdir -p "$records"
printf 'name=legacy-label\nid=legacy-conversation\nparent=main\ndir=%s\nclosed=%s\n' "$tmp" "$(date +%s)" >"$records/legacy"
export LIST_IDS_COLD_MARKER="$records/.ids-v1" LIST_IDS_COLD_DRAW="$tmp/cold-draw"
cat >"$tmp/ui/fzf" <<'STUB'
#!/bin/sh
[ ! -e "$LIST_IDS_COLD_MARKER" ] || exit 2
: >"$LIST_IDS_COLD_DRAW"
exit 1
STUB
chmod +x "$tmp/ui/fzf"
PATH="$tmp/ui:$PATH" "$B/tmux-agents" </dev/null
[ -f "$tmp/cold-draw" ] && [ ! -f "$records/.ids-v1" ]
# Cold migration is measured separately from steady-state list rebuilding;
# use only a temporary queue root, never the user's legacy queue.
ensure_agent_ids "$tmp/queue"
legacy_id="$(record_ids_by_name legacy)"
[ -n "$legacy_id" ] && [ "$(record_get "$legacy_id" id)" = legacy-conversation ]
echo 'ok cold fzf draw precedes migration; isolated migration preserves record'

main_id="$(pane_agent_id %0)"; other_id="$(pane_agent_id "$other")"
records="$(sessions_dir)"; now="$(date +%s)"
record() {
  printf 'agent_id=%s\nname=%s\nkind=codex\nid=conversation-%s\ndir=%s\nparent=%s\nparent_name=old-parent\ndepth=1\nclosed=%s\n' "$1" "$2" "$1" "$tmp" "$3" "$4" >"$records/$1"
}
record a000000000001 duplicate "$main_id" "$((now-120))"
record a000000000002 duplicate "$main_id" "$((now-7200))"
record a000000000003 child a000000000001 "$now"
record "$other_id" duplicate "$main_id" "$now"
count=0
check() { local label="$1"; shift; "$@" || { echo "FAIL $label"; exit 1; }; count=$((count+1)); echo "ok $label"; }
has() { grep -Fq -- "$2" "$1"; }
lacks() { ! has "$@"; }
FZF_PROMPT='all · this window> ' "$B/tmux-agents" --list >"$tmp/rows"
python3 - "$tmp/rows" "$tmp/rendered" "$other_id" <<'PY'
import re,sys
rows=open(sys.argv[1],'rb').read().decode().split('\0')
keys=[row.split(' ',1)[0] for row in rows if row]
assert 'closed:a000000000001' in keys and 'closed:a000000000002' in keys
assert 'closed:a000000000003' in keys # closed parent, not live same-label pane in B
assert 'closed:'+sys.argv[3] not in keys
rendered='\n'.join(row.split(' ',1)[1] for row in rows if row)
assert not re.search(r'a[0-9a-f]{12}',rendered)
closed_rows={row.split(' ',1)[0]: re.sub(r'\x1b\[[0-9;]*m', '', row).splitlines()[-1] for row in rows if row.startswith('closed:')}
assert re.search(r'\b2m\b', closed_rows['closed:a000000000001'])
assert re.search(r'\b2h\b', closed_rows['closed:a000000000002'])
open(sys.argv[2],'w').write(rendered)
PY
check 'rows use hidden IDs and preserve duplicate labels and ancestry' has "$tmp/rendered" duplicate
TMUX_PANE="$other" FZF_PROMPT='agents · this window> ' "$B/tmux-agents" --list >"$tmp/remote"
check 'same-label live parent cannot steal closed descendant window' lacks "$tmp/remote" closed:a000000000003
"$B/tmux-agents" --closed-info closed:a000000000002 >"$tmp/preview"
check 'preview names selected record' has "$tmp/preview" duplicate
check 'preview may show selected ID' has "$tmp/preview" a000000000002
check 'preview resolves current parent label' has "$tmp/preview" main
# Closed references are IDs; default peers resolves labels, opt-in includes IDs.
tmux set -p -t %0 @closed 'a000000000001 a000000000002'
tmux set -p -t %0 @peers "$other"
"$B/tmux-peers" --from main >"$tmp/peers"
check 'default peers closed labels' has "$tmp/peers" 'duplicate, duplicate'
check 'default peers hides IDs' lacks "$tmp/peers" a000000000001
"$B/tmux-peers" --ids --from main >"$tmp/peers-ids"
for aid in "$main_id" "$other_id" a000000000001 a000000000002; do check "peers --ids includes $aid" has "$tmp/peers-ids" "$aid"; done
# Run the real picker acceptance path with a deterministic fzf selection.
LIST_IDS_REAL_TMUX="$(command -v tmux)"
export LIST_IDS_REAL_TMUX LIST_IDS_UI_LOG="$tmp/ui-log"
# New tmux sessions inherit the shim PATH; give them its required variables.
tmux set-environment -g LIST_IDS_REAL_TMUX "$LIST_IDS_REAL_TMUX"
tmux set-environment -g LIST_IDS_UI_LOG "$LIST_IDS_UI_LOG"
cat >"$tmp/ui/fzf" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$LIST_IDS_UI_LOG.args"
printf 'enter\nagents · all windows> \nclosed:a000000000002 duplicate\n'
STUB
cat >"$tmp/ui/tmux" <<'STUB'
#!/bin/sh
if [ "$1" = run-shell ] && [ "${2:-}" = -b ]; then
  case "${3:-}" in *display-popup*) printf '%s\n' "$3" >>"$LIST_IDS_UI_LOG"; exit 0 ;; esac
fi
exec "$LIST_IDS_REAL_TMUX" "$@"
STUB
chmod +x "$tmp/ui/fzf" "$tmp/ui/tmux"
PATH="$tmp/ui:$PATH" "$B/tmux-agents" --client test-client </dev/null
check 'fzf hides ID and full-name lookup fields' has "$tmp/ui-log.args" --with-nth=3..
reopened="$(find_pane_by_id a000000000002)"
check 'selected record reopened exactly' test -n "$reopened"
check 'other duplicate remains closed' test -z "$(find_pane_by_id a000000000001)"
check 'reopened label gets suffix on live conflict' test "$(pane_name "$reopened")" = duplicate-2
for ((i=0; i<100; i++)); do
  tmux capture-pane -p -J -S -100 -t "$reopened" >"$tmp/screen"
  if grep -q 'STUB READY codex.*conversation-a000000000002' "$tmp/screen"; then break; fi
  sleep 0.05
done
check 'resumed stub has selected conversation' has "$tmp/screen" conversation-a000000000002
check 'picker viewer follows ID despite label suffix' has "$tmp/ui-log" "--view $reopened "
: >"$records/.record-a000000000001.lock"
"$B/tmux-agents" --dismiss closed:a000000000001
check 'forget removes exact record lock' test ! -e "$records/.record-a000000000001.lock"
check 'forget removes exact record' test ! -e "$records/a000000000001"
check 'forget preserves other same-label record' test -e "$records/a000000000002"
# Parent display prefers current labels, then the saved fallback when missing.
record a000000000005 fallback a000000000099 "$now"
FZF_PROMPT='all · all windows> ' "$B/tmux-agents" --list >"$tmp/fallback"
check 'missing parent uses saved display label' has "$tmp/fallback" old-parent
"$B/tmux-agents" --closed-info closed:a000000000003 >"$tmp/preview-parent"
check 'closed parent preview falls back after exact forget' has "$tmp/preview-parent" old-parent
# Expiry cleans record locks; work locks live until their pane disappears.
record a000000000006 expired "$main_id" "$((now-8*86400))"
: >"$records/.record-a000000000006.lock"
: >"$records/.record-a000000000005.lock"
agent_set_state %0 working
vanished="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
agent_set_state "$vanished" working
check 'accounting creates per-pane lock' test -e "$records/.work-$vanished.lock"
tmux kill-pane -t "$vanished"
FZF_PROMPT='all · all windows> ' "$B/tmux-agents" --list >"$tmp/expiry"
check 'expiry removes record' test ! -e "$records/a000000000006"
check 'expiry removes corresponding record lock' test ! -e "$records/.record-a000000000006.lock"
check 'expiry keeps retained record lock' test -e "$records/.record-a000000000005.lock"
check 'sweep removes vanished pane lock' test ! -e "$records/.work-$vanished.lock"
check 'sweep preserves live pane lock' test -e "$records/.work-%0.lock"
echo "$count checks passed"
