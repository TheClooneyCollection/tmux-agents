#!/usr/bin/env bash
# Network integration only; ordinary tests never download npm packages.
# Verified skills@1.7.0: https://github.com/vercel-labs/skills/tree/7407f3893ad4dceab546ac002c3ef806e4000c73
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-skills.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/cache" "$scratch/work" "$scratch/stubs"
# No real tmux invocation, including installer configuration discovery.
printf '#!/bin/sh\nexit 1\n' > "$scratch/stubs/tmux"
chmod +x "$scratch/stubs/tmux"
# Start clean: no inherited npm config, NODE_OPTIONS, account map or tmux socket.
env -i PATH="$scratch/stubs:$PATH" HOME="$scratch/home" \
  CODEX_HOME="$scratch/home/.codex" CLAUDE_CONFIG_DIR="$scratch/home/.claude" \
  XDG_CONFIG_HOME="$scratch/home/.config" XDG_DATA_HOME="$scratch/home/.local/share" \
  XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/home/.local/state" \
  TMPDIR="$scratch/tmp" TMP="$scratch/tmp" TEMP="$scratch/tmp" \
  npm_config_cache="$scratch/cache/npm" npm_config_prefix="$scratch/home/npm" \
  npm_config_userconfig="$scratch/home/npmrc" npm_config_globalconfig="$scratch/home/global-npmrc" \
  DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 NO_COLOR=1 CI=1 \
  /bin/bash -s -- "$repo" "$scratch" <<'INNER'
set -euo pipefail
repo=$1 scratch=$2
cd "$scratch/work"
mkdir -p "$CODEX_HOME"
# Node os.homedir() and shell tilde expansion must agree before npm is run.
node -e 'if (require("os").homedir() !== process.env.HOME) process.exit(1)'
[ ~ = "$HOME" ]
cli() { npx --yes skills@1.7.0 "$@" </dev/null; }
cli --version | tee "$scratch/version"
grep -qx '1.7.0' "$scratch/version"
cli --help > "$scratch/help"
for flag in --yes --global --agent --skill --list --copy; do
  grep -q -- "$flag" "$scratch/help"
done
cli add "$repo" --list | tee "$scratch/list"
python3 - "$scratch/list" "$HOME" <<'PY'
import pathlib, re, sys
text = re.sub(r'\x1b\[[0-9;]*m', '', pathlib.Path(sys.argv[1]).read_text())
assert re.search(r'Found 4 skills\b', text), text
names = {'tmux-agents', 'tmux-agents-setup', 'tmux-agents-perf', 'agent-chain'}
listed = set(re.findall(r'^│\s{2,}(\S+)\s*$', text, re.M)) & names
assert listed == names, (listed, text)
assert not list(pathlib.Path(sys.argv[2]).rglob('SKILL.md')), '--list installed skills'
PY
for mode in symlink copy; do
  # Fresh destinations for each mode; all are inside this script's temporary HOME.
  rm -rf "$HOME/.agents" "$HOME/.claude/skills" "$CODEX_HOME/skills"
  args=()
  if [ "$mode" = copy ]; then args=(--copy); fi
  cli add "$repo" --global --agent claude-code codex --skill '*' --yes "${args[@]+"${args[@]}"}"
  python3 - "$repo" "$mode" <<'PY'
import os, pathlib, sys
repo, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
home = pathlib.Path(os.environ['HOME'])
names = {'tmux-agents', 'tmux-agents-setup', 'tmux-agents-perf', 'agent-chain'}
# In this pinned version Codex is a universal agent: its CLI destination is
# ~/.agents/skills, even though agents.ts also declares CODEX_HOME.
for base in (home / '.agents/skills', home / '.claude/skills'):
    assert {p.name for p in base.iterdir()} == names, base
    for name in names:
        dest = base / name
        assert (dest / 'SKILL.md').read_bytes() == (repo / 'skills' / name / 'SKILL.md').read_bytes()
        assert dest.is_symlink() == (mode == 'symlink' and '.claude' in str(base)), dest
assert not (home / '.codex/skills').exists()
PY
  /bin/bash "$repo/install.sh" --force > "$scratch/install-$mode.log"
  python3 - "$repo" "$mode" <<'PY'
import os, pathlib, re, sys
repo, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
home = pathlib.Path(os.environ['HOME'])
for base in (home / '.claude/skills', home / '.codex/skills'):
    for source in (repo / 'skills').iterdir():
        if not (source / 'SKILL.md').is_file():
            continue
        dest = base / source.name
        assert dest.is_symlink() and dest.resolve() == source.resolve(), dest
        backups = list(base.glob(source.name + '.bak.*'))
        expected = mode == 'copy' and base == home / '.claude/skills'
        assert len(backups) == int(expected), (dest, backups)
        for backup in backups:
            assert re.search(r'\.bak\.\d{14}$', backup.name)
            assert not backup.is_symlink()
            assert (backup / 'SKILL.md').read_bytes() == (source / 'SKILL.md').read_bytes()
        canonical = home / '.agents/skills' / source.name
        assert canonical.is_dir() and not canonical.is_symlink()
        assert (canonical / 'SKILL.md').read_bytes() == (source / 'SKILL.md').read_bytes()
rules = home / '.codex/rules/tmux-agents.rules'
assert rules.is_file() and not rules.is_symlink()
assert rules.read_bytes() == (repo / 'integrations/codex/tmux-agents.rules').read_bytes()
PY
done
printf '%s\n' 'skills CLI discovery, symlink/copy installation and installer handoff passed'
INNER
