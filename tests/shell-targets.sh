#!/usr/bin/env bash
# Shell target guards, picker/peer filtering, plain borders and descendant peek.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-shell-targets-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-shell-targets.XXXXXX")"
mkdir -p "$tmp/bin"
for a in claude codex; do
  printf '#!/bin/sh\necho "FAKE %s"\nexec cat\n' "$a" >"$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 60 -c "$tmp" cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
for a in claude codex; do
  p="$(tmux new-window -d -P -F '#{pane_id}' "$tmp/bin/$a")"
  for ((i=0; i<100; i++)); do
    tmux capture-pane -p -t "$p" >"$tmp/screen"
    if grep -q "FAKE $a" "$tmp/screen"; then break; fi
    sleep .02
  done
  grep -q "FAKE $a" "$tmp/screen" || { echo "missing $a stub marker"; exit 1; }
  tmux kill-pane -t "$p"
done
shell="$(tmux split-window -d -P -F '#{pane_id}' 'printf "SHELL OUTPUT MARKER\n"; exec cat')"
other="$(tmux split-window -d -P -F '#{pane_id}' cat)"
tmux set -p -t "$shell" @agent codex-shell
tmux set -p -t "$shell" @shell 1
tmux set -p -t "$shell" @parent %0
tmux set -p -t "$other" @agent codex-peer
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
# Invoked through check.
# shellcheck disable=SC2329
reject_shell() {
  if "$@" >"$tmp/error" 2>&1; then return 1; fi
  grep -q 'codex-shell is a shell, not an agent' "$tmp/error" || { cat "$tmp/error"; return 1; }
}
for target in codex-shell "$shell"; do
  check "connect rejects $target" reject_shell "$B/tmux-connect" --from main "$target"
  check "rename rejects $target" reject_shell "$B/tmux-rename" "$target" changed --exact
  check "split rejects $target" reject_shell "$B/tmux-spawn" codex --from main --split "$target" --name bad task
  check "spawn for rejects $target" reject_shell "$B/tmux-spawn" codex --from main --for "$target" --name bad task
done
check 'connect shell caller' reject_shell "$B/tmux-connect" --from codex-shell codex-peer
check 'rename shell caller' reject_shell "$B/tmux-rename" --from codex-shell codex-peer changed --exact
check 'spawn shell caller' reject_shell "$B/tmux-spawn" codex --from codex-shell --name bad task
check 'connect --as is not applied before rejection' reject_shell "$B/tmux-connect" --from main --as changed codex-shell
check 'caller keeps its name' test "$(pane_name %0)" = main
check 'shell keeps its name' test "$(pane_name "$shell")" = codex-shell
check 'rejected operations create no panes' test "$(tmux list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')" = 3
"$B/tmux-connect" --from main --list >"$tmp/list"
check 'connect list excludes shell' test "$(grep -c codex-shell "$tmp/list" || true)" = 0
check 'connect list retains agent' grep -q codex-peer "$tmp/list"
"$B/tmux-connect" --rows all %0 | tr '\0' '\n' >"$tmp/rows"
check 'picker excludes shell' test "$(grep -c codex-shell "$tmp/rows" || true)" = 0
check 'picker retains agent' grep -q codex-peer "$tmp/rows"
# A stale picker selection must still be guarded after selection.
cat >"$tmp/bin/fzf" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s stale-selection\n' "$SHELL_TARGET_PICK"
STUB
chmod +x "$tmp/bin/fzf"
export SHELL_TARGET_PICK="$shell"
check 'stale picker selection rejects shell' reject_shell env PATH="$tmp/bin:$PATH" "$B/tmux-connect"
"$B/tmux-connect" --from main codex >"$tmp/connected"
check 'type lookup excludes shell with codex prefix' grep -q codex-peer "$tmp/connected"
"$B/tmux-connect" --from main codex@work:0 >"$tmp/connected"
check 'window lookup excludes shell with codex prefix' grep -q codex-peer "$tmp/connected"
# Seed stale connections to verify filtering and border rendering.
tmux set -p -t %0 @peers "$shell $other"
tmux set -p -t "$shell" @peers %0
tmux set -p -t "$shell" @peer_names main
"$B/tmux-peers" --from main >"$tmp/peers"
check 'peers excludes shell' test "$(grep -c codex-shell "$tmp/peers" || true)" = 0
check 'peers retains agent' grep -q codex-peer "$tmp/peers"
check 'shell peers output is plain name' test "$("$B/tmux-peers" --from codex-shell)" = codex-shell
"$B/tmux-peers" --refresh
border="$(tmux display-message -p -t "$shell" "$BORDER_FORMAT")"
check 'shell border contains name' test "$(printf '%s' "$border" | grep -c codex-shell)" = 1
check 'shell border has no peer arrow' test "$(printf '%s' "$border" | grep -c ⇄ || true)" = 0
check 'shell border has no disconnected suffix' test "$(printf '%s' "$border" | grep -c 'not connected' || true)" = 0
for target in codex-shell "$shell"; do
  "$B/tmux-peek" --from main "$target" >"$tmp/peek"
  check "peek descendant shell $target" grep -q 'SHELL OUTPUT MARKER' "$tmp/peek"
done
tmux set -pu -t "$shell" @parent
tmux set -p -t %0 @peers "$shell $other"
if "$B/tmux-peek" --from main codex-shell >"$tmp/error" 2>&1; then
  echo 'FAIL  peek unrelated shell'; fail=1
else
  check 'peek unrelated shell rejected despite stale link' grep -q 'not your descendant shell' "$tmp/error"
fi
# Missing names with dots must keep the closed-by-user diagnostic.
closed_id="$(new_agent_id)"
record_set "$closed_id" name codex-blog.example-1
tmux set -p -t %0 @closed "$closed_id"
for command in spawn peek; do
  if [ "$command" = spawn ]; then
    args=("$B/tmux-spawn" codex --from main --for codex-blog.example-1 --name bad task)
  else
    args=("$B/tmux-peek" --from main codex-blog.example-1)
  fi
  if "${args[@]}" >"$tmp/error" 2>&1; then
    echo "FAIL  $command accepts closed agent"; fail=1
  else
    check "$command preserves closed agent diagnostic" grep -q 'was closed by the user' "$tmp/error"
  fi
done
exit "$fail"
