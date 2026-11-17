#!/usr/bin/env bash
# Install tmux-agents from this checkout: link the commands and skills, copy
# the Codex rules, and print the lines to add to your own config.
#
#   ./install.sh [--home DIR] [--dry-run] [--force]
#
# --home DIR  isolate all writes; ignore outside inherited targets and skip migration
# --force     allow worktree/outside-HOME installs and back up conflicting files
# env: BIN_DIR  where to link the commands (default ~/.local/bin)
#      TMUX_AGENTS_CODEX_HOMES  extra Codex accounts (name=CODEX_HOME ...);
#               their skills and rules are installed too
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dry=0 force=0 sandbox_home=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --force) force=1 ;;
    --home)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo '--home requires a directory' >&2; exit 1; }
      sandbox_home="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Resolve existing symlink ancestors as well as missing paths, without writes.
# Perl is already a runtime dependency; realpath -m is unavailable on macOS.
resolved_path() {
  perl -MCwd=abs_path -MFile::Spec -MFile::Basename=dirname,basename -e '
    sub resolve {
      my ($p) = @_;
      if (-e $p || -l $p) { return abs_path($p) // die "Cannot resolve $p\n" }
      my $parent = resolve(dirname($p));
      my $name = basename($p);
      return $parent if $name eq ".";
      return dirname($parent) if $name eq "..";
      return "$parent/$name";
    }
    print resolve(File::Spec->rel2abs($ARGV[0]));
  ' "$1"
}
inside_home() {
  local resolved
  resolved="$(resolved_path "$1")" || return 1
  case "$resolved" in "$home_root"|"${home_root%/}/"*) return 0 ;; *) return 1 ;; esac
}
refuse() { echo "refusing install: $*; use --home DIR for an isolated install (or --force to override normal-install guards and back up/replace real files)" >&2; exit 1; }

if [ -n "$sandbox_home" ]; then
  case "$sandbox_home" in /*) HOME="$sandbox_home" ;; *) HOME="$PWD/$sandbox_home" ;; esac
  while [ "$HOME" != / ] && [ "${HOME%/}" != "$HOME" ]; do HOME="${HOME%/}"; done
  export HOME
  echo "sandbox home: $HOME"
fi
home_root="$(resolved_path "$HOME")"
if [ "$home_root" = / ]; then
  echo 'refusing install: HOME must not resolve to /; use --home DIR below /' >&2
  exit 1
fi
# Installation discovers accounts only from its environment, never live tmux.
export TMUX_AGENTS_INSTALL_NO_TMUX=1
if [ -n "$sandbox_home" ]; then
  # Filter whitespace-separated account entries without expanding glob characters.
  filtered_map=''
  set -f
  for entry in ${TMUX_AGENTS_CODEX_HOMES:-}; do
    if inside_home "${entry#*=}"; then filtered_map="${filtered_map:+$filtered_map }$entry"; fi
  done
  set +f
  export TMUX_AGENTS_CODEX_HOMES="$filtered_map"
  if [ -n "${CODEX_HOME:-}" ] && ! inside_home "$CODEX_HOME"; then unset CODEX_HOME; fi
  if [ -n "${BIN_DIR:-}" ] && ! inside_home "$BIN_DIR"; then unset BIN_DIR; fi
fi
bin_dir="${BIN_DIR:-$HOME/.local/bin}"
. "$here/bin/lib.sh"

if [ "$force" -eq 0 ] && [ -z "$sandbox_home" ]; then
  git_dir="$(git -C "$here" rev-parse --git-dir 2>/dev/null || true)"
  git_common_dir="$(git -C "$here" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$git_dir" ] && [ -n "$git_common_dir" ]; then
    # Git may return one absolute path and one relative to the checkout.
    git_dir="$(cd "$here" && cd -P "$git_dir" && pwd -P)"
    git_common_dir="$(cd "$here" && cd -P "$git_common_dir" && pwd -P)"
    [ "$git_dir" = "$git_common_dir" ] || refuse 'checkout is a linked git worktree'
  fi
fi
# Discover and validate every destination before linking or removing anything.
codex_map=''
resolve_codex_homes codex_map
codex_homes=("${CODEX_HOME:-$HOME/.codex}" "$HOME/.codex")
set -f
for e in $codex_map; do codex_homes+=("${e#*=}"); done
set +f
# Sandbox installs must never escape through pre-existing directory symlinks,
# even with --force. Individual command/skill links are replaced, not followed.
if [ "$force" -eq 0 ] || [ -n "$sandbox_home" ]; then
  targets=("$bin_dir" "$HOME/.claude/skills")
  for h in "${codex_homes[@]}"; do targets+=("$h" "$h/skills" "$h/rules"); done
  for target in "${targets[@]}"; do
    inside_home "$target" || refuse "write target outside HOME: $target"
  done
fi
if [ -n "$sandbox_home" ] && [ "$dry" -eq 0 ]; then mkdir -p "$HOME"; fi

if ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' 'Note: fzf is required for the agent list (prefix + a).' \
    'Install it with: brew install fzf  (macOS)' \
    '             or: apt install fzf   (Debian/Ubuntu)' \
    'Installation continues; other tmux-agents commands work without fzf.' >&2
fi

run() { if [ "$dry" -eq 1 ]; then echo "would: $*"; else "$@"; fi; }

# Link $1 at $2, replacing an older link but never a real file unless --force.
# A link that already resolves to $1 is kept as is, so relative links survive.
link() {
  if [ -L "$2" ] && [ "$2" -ef "$1" ]; then
    echo "kept $2"
  elif [ -L "$2" ] || [ ! -e "$2" ] || [ "$force" -eq 1 ]; then
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
    local target home_root link_dir part up
    target="$1"
    home_root="$HOME"
    while [ "${home_root%/}" != "$home_root" ]; do home_root="${home_root%/}"; done
    # Count directories below HOME, preserving spaces and supporting Bash 3.2.
    # Keep the existing -ef check above: correct links are never rewritten.
    case "$1" in "$home_root/"*)
      case "$2" in "$home_root/"*)
        link_dir="${2%/*}"
        link_dir="${link_dir#"$home_root"}"
        up=''
        while [ -n "$link_dir" ]; do
          part="${link_dir%%/*}"
          case "$link_dir" in */*) link_dir="${link_dir#*/}" ;; *) link_dir='' ;; esac
          [ -z "$part" ] || up="../$up"
        done
        target="$up${1#"$home_root/"}"
        ;;
      esac
      ;;
    esac
    run ln -sfn "$target" "$2"
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

# A retired entry may be a dangling relative link from a HOME-local install.
# Resolve its existing parent, never follow or remove a user-owned entry.
remove_retired_link() {
  local source="$1" destination="$2" target target_dir source_dir
  [ -L "$destination" ] || return 0
  target="$(readlink "$destination")"
  case "$target" in /*) ;; *) target="${destination%/*}/$target" ;; esac
  while [ "$target" != / ] && [ "${target%/}" != "$target" ]; do target="${target%/}"; done
  target_dir="$(cd -P "${target%/*}" 2>/dev/null && pwd)" || return 0
  source_dir="$(cd -P "${source%/*}" && pwd)" || return 0
  if [ "$target_dir/${target##*/}" = "$source_dir/${source##*/}" ]; then
    run rm "$destination"
  fi
}

remove_retired_link "$here/bin/tmux-clear-context" "$bin_dir/tmux-clear-context"
remove_retired_link "$here/skills/chain-reset" "$HOME/.claude/skills/chain-reset"
# Remove only our retired command link; do not delete a user's own executable.
if [ -L "$bin_dir/tmux-request-state" ] && [ "$(readlink "$bin_dir/tmux-request-state")" = "$here/bin/tmux-request-state" ]; then
  run rm "$bin_dir/tmux-request-state"
fi

# Includes tmux-read for retained messages and tmux-notes for quiet updates.
for f in "$here"/bin/tmux-*; do link "$f" "$bin_dir/$(basename "$f")"; done
link "$here/bin/lib.sh" "$bin_dir/lib.sh"
link "$here/bin/turn-state.sh" "$bin_dir/turn-state.sh"
link "$here/bin/notes-lib.sh" "$bin_dir/notes-lib.sh"

link "$here/skills/tmux-agents" "$HOME/.claude/skills/tmux-agents"
link "$here/skills/tmux-agents-setup" "$HOME/.claude/skills/tmux-agents-setup"
link "$here/skills/tmux-agents-perf" "$HOME/.claude/skills/tmux-agents-perf"
link "$here/skills/agent-chain" "$HOME/.claude/skills/agent-chain"

# Always cover the standard home as well as an explicitly selected account.
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
  remove_retired_link "$here/skills/chain-reset" "$h/skills/chain-reset"
  for skill in "$here"/skills/*; do
    [ -f "$skill/SKILL.md" ] || continue
    link "$skill" "$h/skills/$(basename "$skill")"
  done
  copy "$here/integrations/codex/tmux-agents.rules" "$h/rules/tmux-agents.rules"
done

cat <<EOF

Almost done. Add these to your own config:

1. $HOME/.tmux.conf, then reload tmux:
     %hidden TMUX_AGENTS_BIN="$bin_dir"
     source-file "$here/tmux/tmux-agents.conf"

2. Make sure $bin_dir is on PATH.

3. Claude: merge the "allow" rules from
     $here/integrations/claude/settings.json
   into $HOME/.claude/settings.json.

4. In tmux, start agents with tracking and identity pins:
     tmux-agents start claude
     tmux-agents start codex   (or a configured Codex profile)
   Start a chain in a new window:
     tmux-agents start chain [DIR] [--main AGENT] [--secondary AGENT] [--worker AGENT]
   Inspect role choices: tmux-agents chain-config --sources
   New Codex profiles need this installer rerun after their home exists.
   Launch hooks are passed per process; global agent hook config is not edited.

   Optional, for typing codex directly: a wrapper pins identity only, without tracking:
     fish:      cp $here/integrations/fish/functions/*.fish $HOME/.config/fish/functions/
     bash/zsh:  source $here/integrations/sh/codex.sh   (in $HOME/.bashrc or $HOME/.zshrc)

5. Optional: tell your agents to use tmux-spawn instead of built-in sub agents
   (CLAUDE.md / AGENTS.md); the skill describes it.
EOF

# Upgrade this server only. Outside tmux, the normal tmux command targets its
# default server; a missing server is expected and does not start one.
if [ -z "$sandbox_home" ] && [ "$dry" -eq 0 ] && command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
  migrate_turn_state
fi
