#!/usr/bin/env bash
# Isolated installation, safe force migration, and Codex home resolution.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-install-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-install.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE TMUX_AGENTS_CODEX_HOMES
export HOME="$tmp/home" CODEX_HOME="$tmp/selected home" BIN_DIR="$tmp/bin"
export XDG_STATE_HOME="$tmp/state"
mkdir -p "$HOME/.codex" "$CODEX_HOME" "$tmp/stubs"
real_tmux="$(command -v tmux)"
base_path="$PATH"
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
export PATH="$tmp/stubs:$PATH"
count=0 failures=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; failures=$((failures+1)); fi; }
contains() { grep -Fq -- "$2" "$1"; }
install() { /bin/bash "$here/install.sh" "$@" >"$tmp/output" 2>&1; }
all_skills() {
  local skill
  for skill in "$here"/skills/*; do
    [ -f "$skill/SKILL.md" ] || continue
    [ -L "$1/$(basename "$skill")" ] || return 1
    [ "$(readlink "$1/$(basename "$skill")")" = "$skill" ] || return 1
  done
}
install
check 'fresh Claude links every skill' all_skills "$HOME/.claude/skills"
check 'fresh default Codex links every skill' all_skills "$HOME/.codex/skills"
check 'selected home with spaces links every skill' all_skills "$CODEX_HOME/skills"
check 'rules are real files' test ! -L "$CODEX_HOME/rules/tmux-agents.rules"
check 'rules content copied' cmp -s "$here/integrations/codex/tmux-agents.rules" "$CODEX_HOME/rules/tmux-agents.rules"
rm "$HOME/.codex/skills/tmux-agents"
ln -s "$tmp/missing" "$HOME/.codex/skills/tmux-agents"
install
check 'broken link repaired' all_skills "$HOME/.codex/skills"
rm "$CODEX_HOME/rules/tmux-agents.rules"
printf 'preserve target\n' >"$tmp/old-rules"
ln -s "$tmp/old-rules" "$CODEX_HOME/rules/tmux-agents.rules"
install
check 'old rules symlink becomes real file' test ! -L "$CODEX_HOME/rules/tmux-agents.rules"
check 'old rules target preserved' contains "$tmp/old-rules" 'preserve target'
dest="$HOME/.claude/skills/tmux-agents"
rm "$dest"
mkdir "$dest"
printf 'original directory\n' >"$dest/SKILL.md"
file="$BIN_DIR/tmux-ask"
rm "$file"
printf 'original file\n' >"$file"
install
check 'without force real directory preserved' test ! -L "$dest"
check 'without force real file preserved' contains "$file" 'original file'
install --force --dry-run
check 'dry run shows backup move' contains "$tmp/output" "would: mv $dest $dest.bak."
check 'dry run shows subsequent link' contains "$tmp/output" "would: ln -sfn $here/skills/tmux-agents $dest"
check 'dry run directory unchanged' contains "$dest/SKILL.md" 'original directory'
check 'dry run file unchanged' contains "$file" 'original file'
check 'dry run no backups' test "$(find "$HOME" "$BIN_DIR" -name '*.bak.*' | wc -l | tr -d ' ')" = 0
install --force
check 'force directory now link' test -L "$dest"
check 'force file now link' test -L "$file"
check 'directory backup retained' contains "$dest".bak.*/SKILL.md 'original directory'
check 'file backup retained' contains "$file".bak.* 'original file'
# Freeze time to exercise exact backup-name collisions without sleeps.
printf '#!/bin/sh\nprintf "20261004010203\\n"\n' >"$tmp/stubs/date"
chmod +x "$tmp/stubs/date"
rm "$file"
printf 'new original\n' >"$file"
printf 'old backup\n' >"$file.bak.20261004010203"
if install --force; then check 'backup collision fails' false; else check 'backup collision fails' true; fi
check 'collision keeps original' contains "$file" 'new original'
check 'collision keeps existing backup' contains "$file.bak.20261004010203" 'old backup'
rm "$file"
# Direct calls must not print, must keep settings cache, and work without tmux.
. "$here/bin/lib.sh"
resolve_codex_homes result >"$tmp/helper-output"
check 'unavailable tmux yields empty mapping' test -z "$result"
check 'helper has no stdout' test ! -s "$tmp/helper-output"
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/extra duplicate=$tmp/extra/ missing=$tmp/missing"
mkdir "$tmp/extra"
install
check 'environment mapping works without tmux' all_skills "$tmp/extra/skills"
check 'duplicate home reported once' test "$(grep -Fc "Codex home: $tmp/extra" "$tmp/output")" = 1
check 'missing home explicitly skipped' contains "$tmp/output" "skipped $tmp/missing: no such Codex home"
unset TMUX_AGENTS_CODEX_HOMES
export PATH="$base_path"
"$real_tmux" -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
"$real_tmux" -L "$sock" set -g default-shell /bin/sh
"$real_tmux" -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$("$real_tmux" -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
mkdir "$tmp/option" "$tmp/global" "$tmp/env"
tmux -L "$sock" set-environment -g TMUX_AGENTS_CODEX_HOMES "legacy=$tmp/global"
tmux -L "$sock" set -g @tmux_agents_codex_homes "option=$tmp/option"
install
check 'option-only account installed' all_skills "$tmp/option/skills"
check 'option wins over global fallback' test ! -d "$tmp/global/skills"
TMUX_AGENTS_CODEX_HOMES="override=$tmp/env" install
check 'environment account installed' all_skills "$tmp/env/skills"
check 'environment wins over option' test "$(grep -Fc "Codex home: $tmp/option" "$tmp/output" || true)" = 0
TMUX_AGENTS_CODEX_HOMES='' install
check 'empty environment falls through to option' contains "$tmp/output" "Codex home: $tmp/option"
# Two helper calls keep the original option snapshot in the same shell.
_TMUX_SETTINGS_LOADED=0
resolve_codex_homes first
tmux -L "$sock" set -g @tmux_agents_codex_homes 'changed=/unused'
resolve_codex_homes second
check 'helper keeps settings snapshot' test "$first" = "$second"
tmux -L "$sock" set -gu @tmux_agents_codex_homes
install
check 'legacy global fallback installed' all_skills "$tmp/global/skills"
tmux -L "$sock" set-environment -gu TMUX_AGENTS_CODEX_HOMES
install
check 'default home reported without map' contains "$tmp/output" "Codex home: $HOME/.codex"
printf '\n%s checks, %s failures\n' "$count" "$failures"
[ "$failures" -eq 0 ]
