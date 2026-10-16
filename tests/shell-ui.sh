#!/usr/bin/env bash
# Persistent shell labels, origin-window scope, popup reuse and key binding.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-test-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
unset TMUX_AGENTS_SHELL_KEY TMUX_AGENTS_COMMAND_KEY
export XDG_STATE_HOME="$tmp/state"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 60 -c "$tmp" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
agent() { tmux set -p -t "$1" @tracked 1; tmux set -p -t "$1" @agent "$2"; [ -z "${3:-}" ] || tmux set -p -t "$1" @parent "$3"; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
has() { grep -q "^$2 " "$1"; }
# Invoked indirectly by test helpers or by commands under test.
# shellcheck disable=SC2329
lacks() { ! has "$@"; }
agent %0 main-a
origin="$(tmux display-message -p -t %0 '#{window_id}')"
other="$(tmux new-window -d -t work -P -F '#{pane_id}' cat)"
other_window="$(tmux display-message -p -t "$other" '#{window_id}')"
shell="$(tmux new-session -d -s agents-project -P -F '#{pane_id}' cat)"
owned="$(tmux new-window -d -t agents-project -P -F '#{pane_id}' cat)"
for p in "$shell" "$owned"; do
  tmux set -p -t "$p" @agent "shell-project-${p#%}"
  tmux set -p -t "$p" @shell 1
  tmux set -p -t "$p" @tracked 0
  tmux set -p -t "$p" @shell_origin_window "$origin"
done
tmux set -p -t "$owned" @parent "$other"
export TMUX_PANE=%0
list() { FZF_PROMPT="$1" "$B/tmux-agents" --list | tr '\0' '\n' >"$2"; }
list 'agents · this window> ' "$tmp/local"
check 'independent shell is in default local list' has "$tmp/local" "$shell"
check 'shell has distinct status' grep -Eq 'shell.*shell' "$tmp/local"
check 'owned shell follows parent instead of origin' lacks "$tmp/local" "$owned"
check 'top-level agent stays excluded' lacks "$tmp/local" %0
export TMUX_PANE="$other"
list 'agents · this window> ' "$tmp/other"
check 'independent shell excluded from other window' lacks "$tmp/other" "$shell"
check 'owned shell follows its parent window' has "$tmp/other" "$owned"
list 'agents · all windows> ' "$tmp/all"
check 'all windows includes independent shell' has "$tmp/all" "$shell"
check 'all windows includes owned shell' has "$tmp/all" "$owned"
# Moving the source pane does not change the independent shell origin window.
tmux set -p -t "$shell" @shell_origin_window "$other_window"
list 'agents · this window> ' "$tmp/moved"
check 'origin window metadata controls local scope' has "$tmp/moved" "$shell"
# Existing picker and viewer attach paths must also accept shell panes.
mkdir "$tmp/ui"
export UI_ARGS="$tmp/ui-args" UI_LOG="$tmp/ui-log" UI_PICK="$shell"
UI_REAL_TMUX="$(command -v tmux)"; export UI_REAL_TMUX
cat >"$tmp/ui/fzf" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s\n' "$@" >"$UI_ARGS"
[ "${UI_ABORT:-}" != 1 ] || exit 1
printf 'enter\nagents · this window> \n%s shell\n' "$UI_PICK"
STUB
cat >"$tmp/ui/tmux" <<'STUB'
#!/bin/sh
case "$1" in
  run-shell) printf '%s\n' "$*" >"$UI_LOG"; exit 0 ;;
  -S) printf '%s\n' "$*" >"$UI_LOG.attach"; exit 0 ;;
esac
exec "$UI_REAL_TMUX" "$@"
STUB
chmod +x "$tmp/ui/fzf" "$tmp/ui/tmux"
PATH="$tmp/ui:$PATH" "$B/tmux-agents" --client test-client </dev/null
check 'Enter opens shell with existing viewer' grep -q -- "--view $shell test-client window sub" "$UI_LOG"
check 'ctrl-x uses existing dismiss path' grep -q 'ctrl-x:execute-silent.*--dismiss {1}' "$UI_ARGS"
UI_ABORT=1 PATH="$tmp/ui:$PATH" "$B/tmux-agents" --view "$shell" test-client window sub </dev/null
check 'viewer attaches to shell hidden session' grep -q 'attach-session -t =agents-project' "$UI_LOG.attach"
# Source only the binding setup: avoid activating background hooks in this fixture.
sed -n '/^run-shell .*--shell-binding/p' "$here/tmux/tmux-agents.conf" >"$tmp/binding.conf"
tmux set-environment -g TMUX_AGENTS_BIN "$B"
tmux source-file "$tmp/binding.conf"
tmux list-keys -T prefix S >"$tmp/binding"
check 'default S passes client and source pane' grep -q 'tmux-shell.*--client.*client_name.*--pane.*pane_id' "$tmp/binding"
check 'binding creates independent shell without --from' test "$(grep -c -- --from "$tmp/binding" || true)" = 0
tmux list-keys -T prefix s >"$tmp/default-binding"
check 'lowercase s retains default session picker' grep -q choose-tree "$tmp/default-binding"
tmux set -g @tmux_agents_shell_key F9
tmux source-file "$tmp/binding.conf"
check 're-source removes old S shortcut' test -z "$(tmux list-keys -T prefix S 2>/dev/null || true)"
check 'configured F9 opens shell' test -n "$(tmux list-keys -T prefix F9)"
tmux set -g @tmux_agents_shell_key none
tmux source-file "$tmp/binding.conf"
check 'none removes previous shortcut' test -z "$(tmux list-keys -T prefix F9 2>/dev/null || true)"
TMUX_AGENTS_SHELL_KEY=F10 "$B/tmux-agents" --shell-binding
check 'environment overrides disabled option' test -n "$(tmux list-keys -T prefix F10)"
tmux bind-key -T prefix F10 display-message user-binding
"$B/tmux-agents" --shell-binding
check 'disable preserves user replacement of our old key' test -n "$(tmux list-keys -T prefix F10 | grep user-binding)"
tmux set -g @tmux_agents_shell_key F9
"$B/tmux-agents" --shell-binding
"$B/tmux-agents" --shell-binding
check 're-source same key preserves shortcut' test -n "$(tmux list-keys -T prefix F9)"
# The picker close action reaches lifecycle cleanup and never creates a record.
"$B/tmux-agents" --dismiss "$shell"
check 'picker dismiss closes shell pane' test -z "$(tmux list-panes -a -F '#{pane_id}' | grep -Fx "$shell" || true)"
[ "$fail" -eq 0 ] && echo 'all passed' || echo 'some failed'
exit "$fail"
