#!/usr/bin/env bash
# Installer isolation: inherited accounts, linked worktrees and tmux discovery.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-install-guard.XXXXXX")"
sock="tmux-install-guard-$$"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE
export XDG_STATE_HOME="$tmp/state"
mkdir -p "$tmp/home/.codex" "$tmp/outside/codex" "$tmp/outside/extra" "$tmp/outside/bin" "$tmp/stubs" "$tmp/copy"
printf 'keep me\n' > "$tmp/outside/codex/sentinel"
ln -s missing "$tmp/outside/extra/existing-link"
cp -R "$here/bin" "$here/skills" "$here/integrations" "$tmp/copy/"
cp "$here/install.sh" "$tmp/copy/"
real_tmux="$(command -v tmux)"
printf '#!/bin/sh\nprintf "unexpected tmux call\\n" >> "%s"\nexit 1\n' "$tmp/tmux-calls" > "$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
count=0
check() { local label="$1"; shift; "$@" || { echo "FAIL: $label"; exit 1; }; count=$((count+1)); echo "ok: $label"; }
contains() { grep -Fq -- "$2" "$1"; }
snapshot() {
  find "$tmp/outside" -ls
  find "$tmp/outside" -type f -exec cksum {} \;
}
snapshot > "$tmp/before"
# Every non-sandbox call uses a completely scrubbed environment and fake HOME.
install() {
  env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" \
    CODEX_HOME="$tmp/outside/codex" TMUX_AGENTS_CODEX_HOMES="extra=$tmp/outside/extra" \
    BIN_DIR="$tmp/outside/bin" /bin/bash "$tmp/copy/install.sh" "$@" > "$tmp/output" 2>&1
}
if install; then echo 'FAIL: outside targets accepted'; exit 1; fi
check 'refusal names isolated install flag' contains "$tmp/output" '--home DIR'
check 'force hint explains replacement of real files' contains "$tmp/output" 'back up/replace real files'
check 'refusal precedes writes' test ! -e "$tmp/home/.claude"
if install --dry-run; then echo 'FAIL: dry-run skipped guard'; exit 1; fi
check 'dry-run also refuses' contains "$tmp/output" 'write target outside HOME'
install --home "$tmp/home"
check 'sandbox banner is first' test "$(head -n 1 "$tmp/output")" = "sandbox home: $tmp/home"
check 'sandbox commands use default bin' test -L "$tmp/home/.local/bin/tmux-ask"
check 'sandbox configuration uses sandbox paths' contains "$tmp/output" "$tmp/home/.claude/settings.json"
check 'sandbox installs default Codex skills' test -L "$tmp/home/.codex/skills/tmux-agents"
check 'sandbox never queries tmux' test ! -e "$tmp/tmux-calls"
snapshot > "$tmp/after"
check 'inherited outside targets untouched' cmp -s "$tmp/before" "$tmp/after"
# CODEX_HOME alone must be checked, even without an extra account map.
if env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" CODEX_HOME="$tmp/outside/codex" \
  TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1; then
  echo 'FAIL: outside CODEX_HOME accepted'; exit 1
fi
check 'CODEX_HOME alone is refused' contains "$tmp/output" "$tmp/outside/codex"
if env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" \
  TMUX_AGENTS_CODEX_HOMES="extra=$tmp/outside/extra" /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1; then
  echo 'FAIL: outside account map accepted'; exit 1
fi
check 'extra account map alone is refused' contains "$tmp/output" "$tmp/outside/extra"
# Reject symlink ancestors before any writes.
ln -s "$tmp/outside/bin" "$tmp/home/escape"
if env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" BIN_DIR="$tmp/home/escape" \
  TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1; then
  echo 'FAIL: symlink escape accepted'; exit 1
fi
check 'symlink escape refused' contains "$tmp/output" 'write target outside HOME'
install --home "$tmp/new-home"
check 'sandbox creates missing home' test -d "$tmp/new-home/.local/bin"
install --home "$tmp/dry-home" --dry-run
check 'sandbox dry-run makes no directories' test ! -e "$tmp/dry-home"
# Even force cannot turn / into an isolation boundary. Dry-run prevents writes
# if this regression reappears, including for the explicit HOME=/ case.
if install --home / --force --dry-run; then echo 'FAIL: root sandbox accepted'; exit 1; fi
check 'root sandbox refused' contains "$tmp/output" 'HOME must not resolve to /'
if env -i PATH="$tmp/stubs:$PATH" HOME=/ TMUX_AGENTS_CODEX_HOMES='' \
  /bin/bash "$tmp/copy/install.sh" --force --dry-run > "$tmp/output" 2>&1; then
  echo 'FAIL: root HOME accepted'; exit 1
fi
check 'root HOME refused' contains "$tmp/output" 'HOME must not resolve to /'
# Glob characters in account paths are literal, even when they match siblings.
mkdir -p "$tmp/home/profile*" "$tmp/home/profile-other" "$tmp/glob-cwd/literal=$tmp/home/profile-other"
(cd "$tmp/glob-cwd" && env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX_AGENTS_CODEX_HOMES="literal=$tmp/home/profile*" \
  /bin/bash "$tmp/copy/install.sh" --home "$tmp/home") > "$tmp/output" 2>&1
check 'literal glob account receives skills' test -L "$tmp/home/profile*/skills/tmux-agents"
check 'glob sibling remains untouched' test ! -e "$tmp/home/profile-other/skills"
# A HOME-internal configuration directory can itself lead outside.
mkdir -p "$tmp/linked-home"
ln -s "$tmp/outside" "$tmp/linked-home/.claude"
if install --home "$tmp/linked-home" --force; then echo 'FAIL: sandbox follows directory escape'; exit 1; fi
check 'sandbox force cannot escape home' contains "$tmp/output" 'write target outside HOME'
# Exercise a true linked worktree, not the checkout running this suite.
git init -q "$tmp/repo"
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.com commit -qm fixture --allow-empty
# A tarball copy nested inside a dotfiles repository is not a linked worktree.
mkdir "$tmp/repo/copy"
(cd "$tmp/copy" && tar -cf "$tmp/copy.tar" .)
tar -xf "$tmp/copy.tar" -C "$tmp/repo/copy"
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX_AGENTS_CODEX_HOMES='' \
  /bin/bash "$tmp/repo/copy/install.sh" > "$tmp/output" 2>&1
check 'tarball under outer repository installs normally' test "$tmp/home/.local/bin/tmux-ask" -ef "$tmp/repo/copy/bin/tmux-ask"
git -C "$tmp/repo" worktree add -q -b fixture "$tmp/worktree"
cp -R "$tmp/copy/". "$tmp/worktree/"
if env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" CODEX_HOME="$tmp/outside/codex" \
  TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$tmp/worktree/install.sh" --dry-run > "$tmp/output" 2>&1; then
  echo 'FAIL: linked worktree accepted'; exit 1
fi
check 'worktree refusal names reason' contains "$tmp/output" 'linked git worktree'
check 'worktree refusal names sandbox alternative' contains "$tmp/output" '--home DIR'
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX_AGENTS_CODEX_HOMES='' \
  /bin/bash "$tmp/worktree/install.sh" --home "$tmp/home" > "$tmp/output" 2>&1
check 'worktree sandbox install succeeds' test "$tmp/home/.local/bin/tmux-ask" -ef "$tmp/worktree/bin/tmux-ask"
mkdir -p "$tmp/forced-codex"
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" CODEX_HOME="$tmp/forced-codex" \
  TMUX_AGENTS_CODEX_HOMES='' /bin/bash "$tmp/worktree/install.sh" --force > "$tmp/output" 2>&1
check 'force bypasses worktree and outside-home guards' test -L "$tmp/forced-codex/skills/tmux-agents"
# Only a private server advertises the sentinel through settings/global env.
"$real_tmux" -L "$sock" -f /dev/null new-session -d -s test /bin/cat
"$real_tmux" -L "$sock" set -g default-shell /bin/sh
"$real_tmux" -L "$sock" has-session || exit 1
socket="$("$real_tmux" -L "$sock" display -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe test socket'; exit 1 ;; esac
export TMUX="$socket,1,0"
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$real_tmux" "$socket" > "$tmp/stubs/tmux"
"$real_tmux" -L "$sock" set -g @tmux_agents_codex_homes "sentinel=$tmp/outside/extra"
"$real_tmux" -L "$sock" set-environment -g TMUX_AGENTS_CODEX_HOMES "sentinel=$tmp/outside/codex"
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX="$TMUX" TMUX_AGENTS_CODEX_HOMES='' \
  /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1
check 'installer empty map ignores tmux option' test ! -e "$tmp/outside/extra/skills"
"$real_tmux" -L "$sock" set -gu @tmux_agents_codex_homes
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX="$TMUX" TMUX_AGENTS_CODEX_HOMES='' \
  /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1
check 'installer empty map ignores tmux global env' test ! -e "$tmp/outside/codex/skills"
"$real_tmux" -L "$sock" set -g @tmux_agents_codex_homes "sentinel=$tmp/outside/extra"
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX="$TMUX" \
  /bin/bash "$tmp/copy/install.sh" --home "$tmp/home" > "$tmp/output" 2>&1
check 'sandbox ignores tmux settings with unset map' test ! -e "$tmp/outside/extra/skills"
env -i PATH="$tmp/stubs:$PATH" HOME="$tmp/home" TMUX="$TMUX" \
  /bin/bash "$tmp/copy/install.sh" > "$tmp/output" 2>&1
check 'normal install ignores tmux settings with unset map' test ! -e "$tmp/outside/extra/skills"
snapshot > "$tmp/after"
check 'sentinels remain byte-for-byte unchanged' cmp -s "$tmp/before" "$tmp/after"
printf '%s checks, 0 failures\n' "$count"
