#!/usr/bin/env bash
# Missing fzf: nonfatal install, automated errors, and a real persistent popup.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-fzf-required-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-fzf-required.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE TMUX_AGENTS_CODEX_HOMES
mkdir -p "$tmp/path" "$tmp/home/.codex" "$tmp/stubs"
# An allowlist, not /usr/bin or a prepended stub: system fzf is truly invisible.
for cmd in bash dirname basename mkdir ln cp rm date awk git stat sort tr sed cat tmux id od cut wc head tail mktemp perl column find grep; do
  ln -s "$(command -v "$cmd")" "$tmp/path/$cmd"
done
for agent in claude codex; do
  printf '#!/bin/sh\nprintf "stub agent\\n"\nexec cat\n' >"$tmp/stubs/$agent"
  chmod +x "$tmp/stubs/$agent"
done
export TMUX_SPAWN_BIN="$tmp/stubs" XDG_STATE_HOME="$tmp/state"
if PATH="$tmp/path" /bin/bash -c 'command -v fzf'; then echo 'FAIL: fzf leaked into PATH'; exit 1; fi
# A failing tmux stub prevents installation from looking at any live server.
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
env PATH="$tmp/stubs:$tmp/path" HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" BIN_DIR="$tmp/bin" \
  /bin/bash "$here/install.sh" >"$tmp/install-output" 2>&1
for text in 'fzf is required' 'brew install fzf' 'apt install fzf' 'Installation continues'; do
  grep -Fq "$text" "$tmp/install-output"
done
[ -L "$tmp/bin/tmux-agents" ]
echo 'ok    installation succeeds and explains missing fzf'
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# Python provides deadlines and a real attached PTY for display-popup, while
# the tested commands see only the allowlist PATH. No real agents are launched.
python3 "$here/tests/helpers/fzf-required.py" "$here" "$tmp" "$sock"
