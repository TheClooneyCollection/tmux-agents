#!/usr/bin/env bash
# Install tmux-agents from this checkout: link the commands and skills, copy
# the Codex rules, and print the lines to add to your own config.
#
#   ./install.sh [--dry-run] [--force]
#
# env: BIN_DIR  where to link the commands (default ~/.local/bin)
#      TMUX_AGENTS_CODEX_HOMES  extra Codex accounts (name=CODEX_HOME ...);
#               their skills and rules are installed too
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
. "$here/bin/lib.sh"
dry=0 force=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' 'Note: fzf is required for the agent list (prefix + a).' \
    'Install it with: brew install fzf  (macOS)' \
    '             or: apt install fzf   (Debian/Ubuntu)' \
    'Installation continues; other tmux-agents commands work without fzf.' >&2
fi

run() { if [ "$dry" -eq 1 ]; then echo "would: $*"; else "$@"; fi; }

# Link $1 at $2, replacing an older link but never a real file unless --force.
link() {
  if [ -L "$2" ] || [ ! -e "$2" ] || [ "$force" -eq 1 ]; then
    run mkdir -p "$(dirname "$2")"
    if [ ! -L "$2" ] && [ -e "$2" ]; then
      local backup
      backup="$2.bak.$(date +%Y%m%d%H%M%S)"
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        echo "refusing to overwrite backup: $backup" >&2
        return 1
      fi
      run mv "$2" "$backup"
    fi
    run ln -sfn "$1" "$2"
    echo "linked $2"
  else
    echo "skipped $2: exists and isn't a link (use --force)" >&2
  fi
}

# Copy $1 to $2 (Codex skips symlinked .rules files).
copy() {
  run mkdir -p "$(dirname "$2")"
  # Never follow an old rules symlink: Codex requires a real file.
  if [ -L "$2" ]; then run rm "$2"; fi
  run cp "$1" "$2"
  echo "copied $2"
}

for f in "$here"/bin/tmux-*; do link "$f" "$bin_dir/$(basename "$f")"; done
link "$here/bin/lib.sh" "$bin_dir/lib.sh"

link "$here/skills/tmux-agents" "$HOME/.claude/skills/tmux-agents"
link "$here/skills/tmux-agents-setup" "$HOME/.claude/skills/tmux-agents-setup"
link "$here/skills/tmux-agents-perf" "$HOME/.claude/skills/tmux-agents-perf"
link "$here/skills/agent-chain" "$HOME/.claude/skills/agent-chain"

# Always cover the standard home as well as an explicitly selected account.
codex_map=''
resolve_codex_homes codex_map
codex_homes=("${CODEX_HOME:-$HOME/.codex}" "$HOME/.codex")
for e in $codex_map; do codex_homes+=("${e#*=}"); done
seen_homes=()
for h in "${codex_homes[@]}"; do
  # Ignore trailing slashes when deduplicating account paths.
  while [ "$h" != / ] && [ "${h%/}" != "$h" ]; do h="${h%/}"; done
  duplicate=0
  for seen in "${seen_homes[@]+"${seen_homes[@]}"}"; do
    [ "$h" != "$seen" ] || duplicate=1
  done
  [ "$duplicate" -eq 0 ] || continue
  seen_homes+=("$h")
  [ -d "$h" ] || { echo "skipped $h: no such Codex home" >&2; continue; }
  echo "Codex home: $h"
  for skill in "$here"/skills/*; do
    [ -f "$skill/SKILL.md" ] || continue
    link "$skill" "$h/skills/$(basename "$skill")"
  done
  copy "$here/integrations/codex/tmux-agents.rules" "$h/rules/tmux-agents.rules"
done

cat <<EOF

Almost done. Add these to your own config:

1. ~/.tmux.conf, then reload tmux:
     %hidden TMUX_AGENTS_BIN="$bin_dir"
     source-file "$here/tmux/tmux-agents.conf"

2. Make sure $bin_dir is on PATH.

3. Claude: merge the "allow" rules from
     $here/integrations/claude/settings.json
   into ~/.claude/settings.json.

4. Codex: start it through a wrapper that pins its tmux identity:
     fish:      cp $here/integrations/fish/functions/*.fish ~/.config/fish/functions/
     bash/zsh:  source $here/integrations/sh/codex.sh   (in ~/.bashrc or ~/.zshrc)

5. Optional: tell your agents to use tmux-spawn instead of built-in sub agents
   (CLAUDE.md / AGENTS.md); the skill describes it.
EOF
