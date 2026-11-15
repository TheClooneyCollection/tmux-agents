#!/usr/bin/env bash
# Spawned Codex folder trust: attention, parent notice, manual choice, profiles,
# normal startup, and identity-safe cleanup. Only stub agents/private socket.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-codex-startup-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-codex-startup.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/profile"
cat >"$tmp/bin/codex" <<'STUB'
#!/usr/bin/env python3
import os, sys
print("STUB CODEX", flush=True)
normal = any("normal-start" in arg for arg in sys.argv)
if normal:
    print("Folder access /example; Trust this folder?; 1. Trust and continue; 2. Back to Agent Command Center")
    print("› ", end="", flush=True)
else:
    print("Folder access " + os.getcwd())
    print("Trust this folder?")
    print("Codex can read, edit, and run files here, subject to your permission settings.")
    print("Folder settings can run code automatically, even without a model request.")
    print("Continue only if you trust these files. Your trust decision will be saved.")
    print("1. Trust and continue")
    print("2. Back to Agent Command Center")
    print("enter continue · esc back", flush=True)
for line in sys.stdin:
    print("STUB INPUT " + repr(line), flush=True)
    print("\033[2J\033[H› ", end="", flush=True)
STUB
cat >"$tmp/bin/claude" <<'STUB'
#!/bin/sh
printf 'STUB CLAUDE
'
exec cat
STUB
chmod +x "$tmp/bin/codex" "$tmp/bin/claude"
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_CODEX_HOMES
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 -c "$tmp/project" 'stty -echo; exec cat'
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -g @tmux_agents_chip_fps 1
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0 count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
option() { tmux show-option -pqv -t "$1" "$2"; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
# Invoked through check.
# shellcheck disable=SC2329
wait_option() {
  local i
  for ((i=0; i<100; i++)); do
    [ "$(option "$1" "$2")" = "$3" ] && return 0
    sleep .05
 done
  return 1
}
# Invoked through check.
# shellcheck disable=SC2329
wait_text() {
  local i
  for ((i=0; i<100; i++)); do
    tmux capture-pane -p -t "$1" >"$tmp/screen"
    grep -Fq "$2" "$tmp/screen" && return 0
    sleep .05
 done
  return 1
}
# Invoked through check.
# shellcheck disable=SC2329
wait_permission() {
  local i
  for ((i=0; i<100; i++)); do
    [ -n "$(option "$1" @codex_startup_wait)" ] && return 0
    sleep .05
 done
  return 1
}
for kind in codex codex-test; do
  tmux set -g @tmux_agents_codex_homes "codex-test=$tmp/profile"
  "$B/tmux-spawn" "$kind" --from main --exact --name "$kind-trust" 'trust-start' >"$tmp/spawn"
  pane="$(pane_of "$kind-trust")"
  check "$kind stub launched" wait_text "$pane" 'STUB CODEX'
  check "$kind folder trust requests permission" wait_permission "$pane"
  check "$kind work clock paused" test -z "$(option "$pane" @turn_start)"
  check "$kind retains trust screen, no automatic choice" wait_text "$pane" 'Trust this folder?'
  check "$kind reason visible" test "$(option "$pane" @activity)" = 'waiting for folder trust confirmation'
  "$B/tmux-agents" --chip >"$tmp/chip"
  check "$kind chip shows permission" grep -qi 'PERMISSION' "$tmp/chip"
  FZF_PROMPT='agents · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' >"$tmp/list"
  check "$kind list shows permission" grep -q '⚠ permission' "$tmp/list"
  check "$kind parent learns task did not start" wait_text %0 "$kind-trust is waiting for folder trust confirmation. The task has not started."
  # Only the test user makes this choice; the observer must never send keys.
  tmux send-keys -t "$pane" Enter
  check "$kind manual choice reaches prompt" wait_text "$pane" '›'
  check "$kind permission cleared after choice" wait_option "$pane" @perm_since ''
  check "$kind startup marker cleared" test -z "$(option "$pane" @codex_startup_wait)"
  check "$kind work resumes" test -n "$(option "$pane" @turn_start)"
  tmux capture-pane -p -S -100 -t %0 >"$tmp/parent"
  check "$kind parent notified once" test "$(grep -c "$kind-trust is waiting for folder trust confirmation" "$tmp/parent")" = 1
  "$B/tmux-dismiss" --from main "$kind-trust" >/dev/null
done
"$B/tmux-spawn" codex --from main --exact --name normal 'normal-start' >"$tmp/spawn"
pane="$(pane_of normal)"
check 'normal stub reaches prompt' wait_text "$pane" '›'
/bin/bash "$B/tmux-agents-codex-startup.sh" "$pane" "$(pane_agent_id "$pane")" "$$"
check 'normal startup with quoted trust text has no permission' test -z "$(option "$pane" @perm_since)"
"$B/tmux-spawn" claude --from main --exact --name claude-normal 'normal-start' >"$tmp/spawn"
check 'Claude stub runs normally' wait_text "$(pane_of claude-normal)" 'STUB CLAUDE'
check 'Claude has no Codex permission marker' test -z "$(option "$(pane_of claude-normal)" @codex_startup_wait)"
# Guarded cleanup cannot modify a replacement or erase another permission.
id="$(pane_agent_id "$pane")"
_agent_work "$pane" startup-perm on '' "$id"
tmux set -p -t "$pane" @agent_id a111111111111
tmux set -p -t "$pane" @perm_since 123
_agent_work "$pane" startup-perm '' '' "$id"
check 'old observer cannot clear replacement permission' test "$(option "$pane" @perm_since)" = 123
tmux set -p -t "$pane" @agent_id "$id"
_agent_work "$pane" startup-perm '' '' "$id"
check 'observer preserves a newer permission' test "$(option "$pane" @perm_since)" = 123
printf '%s checks, %s failures\n' "$count" "$fail"
exit "$fail"
