#!/usr/bin/env bash
# Fresh installation contract. Requires bash 3.2+, python3 and standard Unix tools.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/tmux-ci-install.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
unset TMUX TMUX_PANE TMUX_AGENTS_CODEX_HOMES
export HOME="$tmp/tree/home" CODEX_HOME="$tmp/tree/selected home"
export BIN_DIR="$tmp/tree/bin" XDG_STATE_HOME="$tmp/tree/state"
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/tree/extra"
mkdir -p "$HOME/.codex" "$CODEX_HOME" "$tmp/tree/extra" "$tmp/stubs"
# Even library fallback probes must not contact a developer's default server.
printf '#!/bin/sh\nexit 1\n' >"$tmp/stubs/tmux"
chmod +x "$tmp/stubs/tmux"
export PATH="$tmp/stubs:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
install() { /bin/bash "$here/install.sh" "$@" >"$tmp/install.log" 2>&1 </dev/null || { cat "$tmp/install.log"; return 1; }; }
assert_link() {
  [ -L "$1" ] && [ -e "$1" ] && [ "$(readlink "$1")" = "$2" ] || fail "incorrect link: $1"
}
verify() {
  local dest skill home command
  for dest in "$HOME/.claude/skills" "$HOME/.codex/skills" "$CODEX_HOME/skills" "$tmp/tree/extra/skills"; do
    for skill in tmux-agents tmux-agents-setup tmux-agents-perf agent-chain; do
      assert_link "$dest/$skill" "$here/skills/$skill"
      [ -f "$dest/$skill/SKILL.md" ] || fail "missing SKILL.md: $dest/$skill"
    done
  done
  for home in "$HOME/.codex" "$CODEX_HOME" "$tmp/tree/extra"; do
    [ -f "$home/rules/tmux-agents.rules" ] && [ ! -L "$home/rules/tmux-agents.rules" ] || fail "rules must be a real file: $home"
    cmp -s "$here/integrations/codex/tmux-agents.rules" "$home/rules/tmux-agents.rules" || fail "rules differ: $home"
    grep -Fxq "Codex home: $home" "$tmp/install.log" || fail "home not reported: $home"
  done
  for command in "$here"/bin/tmux-* "$here/bin/lib.sh"; do
    assert_link "$BIN_DIR/${command##*/}" "$command"
  done
}
# lstat never follows links. Strict mode includes inode/timestamps to detect
# rewrites of identical bytes; content mode checks rerun's observable result.
snapshot() {
  python3 - "$tmp/tree" "$1" <<'PY'
import hashlib, json, os, stat, sys
root, mode = sys.argv[1:]
rows = []
def visit(path):
    info = os.lstat(path)
    row = [os.path.relpath(path, root), info.st_mode]
    if mode == "strict":
        row += [info.st_ino, info.st_mtime_ns, info.st_ctime_ns]
    if stat.S_ISLNK(info.st_mode):
        row.append(os.readlink(path))
    elif stat.S_ISREG(info.st_mode):
        with open(path, "rb") as source:
            row.append(hashlib.sha256(source.read()).hexdigest())
    rows.append(row)
    if stat.S_ISDIR(info.st_mode):
        for name in sorted(os.listdir(path)):
            visit(os.path.join(path, name))
visit(root)
print(json.dumps(rows, ensure_ascii=True))
PY
}
snapshot strict >"$tmp/before"
install --dry-run
snapshot strict >"$tmp/after"
cmp -s "$tmp/before" "$tmp/after" || fail 'fresh dry-run changed destination tree'
install
verify
echo 'ok: fresh install covers commands, four skills, real rules and reported homes'
snapshot content >"$tmp/before"
install
verify
snapshot content >"$tmp/after"
cmp -s "$tmp/before" "$tmp/after" || fail 'rerun changed installed content'
echo 'ok: installation rerun is idempotent'
dest="$HOME/.claude/skills/tmux-agents"
rm "$dest"
mkdir "$dest"
printf 'keep original directory\n' >"$dest/SKILL.md"
snapshot strict >"$tmp/before"
install --force --dry-run
snapshot strict >"$tmp/after"
cmp -s "$tmp/before" "$tmp/after" || fail 'force dry-run changed destination tree'
echo 'ok: force dry-run leaves entire destination tree unchanged'
install --force
verify
set -- "$dest".bak.*
[ "$#" -eq 1 ] && [ -d "$1" ] && [ ! -L "$1" ] || fail 'expected one real directory backup'
printf 'keep original directory\n' >"$tmp/expected"
cmp -s "$tmp/expected" "$1/SKILL.md" || fail 'backup content changed'
echo 'ok: force migrates real directory and preserves original in backup'
