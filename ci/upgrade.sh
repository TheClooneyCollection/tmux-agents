#!/usr/bin/env bash
# Offline v1.9.0 -> current checkout upgrade. Requires git tag v1.9.0,
# tmux, bash 3.2+ and standard Unix tools. Never launches real agents.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/tmux-ci-upgrade.XXXXXX)"
sock="tmux-ci-upgrade-$$"
# shellcheck source=tests/helpers/cleanup.sh
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE TMUX_AGENTS_CODEX_HOMES TMUX_AGENTS_LIST_CLIENT
export HOME="$tmp/home" CODEX_HOME="$tmp/selected" BIN_DIR="$tmp/bin"
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_CODEX_HOMES="extra=$tmp/extra"
checkout="$tmp/installation"
mkdir -p "$HOME/.codex" "$CODEX_HOME" "$tmp/extra" "$checkout" "$tmp/stubs"
fail() { echo "FAIL: $*" >&2; exit 1; }
# Archive the tag locally; do not checkout or mutate any developer worktree.
(cd "$here" && git archive v1.9.0) >"$tmp/old.tar"
tar -xf "$tmp/old.tar" -C "$checkout"
# Installation must not query the user's tmux server, even for settings.
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
PATH="$tmp/stubs:$PATH" /bin/bash "$checkout/install.sh" >"$tmp/old.log" 2>&1 </dev/null
for dest in "$HOME/.claude/skills/tmux-agents" "$CODEX_HOME/skills/tmux-agents" "$tmp/extra/skills/tmux-agents"; do
  [ -L "$dest" ] && [ -f "$dest/SKILL.md" ] || fail "old install missing: $dest"
done
echo 'ok: v1.9.0 installed from local tag archive'
# Keep exactly the same installation path while replacing its contents.
(cd "$here" && tar -cf "$tmp/current.tar" bin skills integrations tmux install.sh)
rm -rf "$checkout"
mkdir "$checkout"
tar -xf "$tmp/current.tar" -C "$checkout"
for dest in "$HOME/.claude/skills/tmux-agents" "$CODEX_HOME/skills/tmux-agents" "$tmp/extra/skills/tmux-agents"; do
  [ -L "$dest" ] && [ ! -e "$dest" ] || fail "expected old broken skill link: $dest"
done
echo 'ok: same-path upgrade reproduces broken legacy skill links'
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || fail 'test server unavailable'
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) fail 'unsafe test socket' ;; esac
export TMUX="$S,1,0"
TMUX_PANE="$(tmux -L "$sock" list-panes -F '#{pane_id}')"
export TMUX_PANE
# Disable animation/background daemon. No agent sessions are created.
tmux -L "$sock" set -g @tmux_agents_chip_fps 1
"$BIN_DIR/tmux-agents" --chip-layout on >"$tmp/layout.out" 2>"$tmp/layout.err" </dev/null
for dest in "$HOME/.claude/skills/tmux-agents" "$CODEX_HOME/skills/tmux-agents" "$tmp/extra/skills/tmux-agents"; do
  grep -Fq "broken skill symlink: $dest;" "$tmp/layout.err" || fail "warning missing: $dest"
done
grep -Fq 'rerun install.sh from the installation checkout' "$tmp/layout.err" || fail 'repair instructions missing'
if grep -Fq 'broken skill symlink' "$tmp/layout.out"; then fail 'warning leaked to stdout'; fi
echo 'ok: isolated layout activation warns and explains repair'
/bin/bash "$checkout/install.sh" >"$tmp/new.log" 2>&1 </dev/null
for dest in "$HOME/.claude/skills" "$HOME/.codex/skills" "$CODEX_HOME/skills" "$tmp/extra/skills"; do
  for skill in tmux-agents tmux-agents-setup tmux-agents-perf agent-chain; do
    [ -L "$dest/$skill" ] && [ -f "$dest/$skill/SKILL.md" ] || fail "skill not repaired: $dest/$skill"
    [ "$(readlink "$dest/$skill")" = "$checkout/skills/$skill" ] || fail "wrong repaired target: $dest/$skill"
  done
done
for command in "$checkout"/bin/tmux-* "$checkout/bin/lib.sh"; do
  dest="$BIN_DIR/${command##*/}"
  [ -L "$dest" ] && [ -e "$dest" ] && [ "$(readlink "$dest")" = "$command" ] || fail "command not repaired: $dest"
done
for home in "$HOME/.codex" "$CODEX_HOME" "$tmp/extra"; do
  [ -f "$home/rules/tmux-agents.rules" ] && [ ! -L "$home/rules/tmux-agents.rules" ] || fail "rules not real: $home"
  cmp -s "$checkout/integrations/codex/tmux-agents.rules" "$home/rules/tmux-agents.rules" || fail "rules differ: $home"
done
"$BIN_DIR/tmux-agents" --chip-layout on >"$tmp/repaired.out" 2>"$tmp/repaired.err" </dev/null
[ ! -s "$tmp/repaired.err" ] || fail 'layout still warns after reinstall'
echo 'ok: reinstall repairs all commands, four skills and rules; layout is quiet'
