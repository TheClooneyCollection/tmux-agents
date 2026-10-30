#!/usr/bin/env bash
# tmux-spawn --message-file on an isolated server.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-spawn-message-file-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-spawn-message-file.XXXXXX")"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/codex" <<'STUB'
#!/bin/sh
echo 'FAKE codex'
exec cat
STUB
chmod +x "$tmp/bin/codex"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 50 -c "$tmp" cat </dev/null
tmux -L "$sock" has-session || { echo 'ABORT: private test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe test socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail() { echo "FAIL: $*" >&2; exit 1; }
file="$tmp/task.txt"
# shellcheck disable=SC2016
printf 'literal $HOME $(touch %s/expanded)\nsecond line\n' "$tmp" >"$file"
TMUX_PANE=%0 "$B/tmux-spawn" codex --name owner </dev/null >/dev/null
owner="$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk '$2 ~ /-owner$/ {print $1; exit}')"
[ -n "$owner" ] || fail 'owner agent exists'
owner_name="$(tmux display-message -p -t "$owner" '#{@agent}')"
printf 'ignored task stdin payload' | TMUX_PANE=%0 "$B/tmux-spawn" codex --member --for "$owner_name" --split "$owner" --right --size 35% --name message-file --message-file "$file" >/dev/null
pane="$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk '$2 ~ /-message-file$/ {print $1; exit}')"
[ -n "$pane" ] || fail 'spawned split exists'
case "$(tmux display-message -p -t "$pane" '#{@agent}')" in *-message-file) ;; *) fail 'name option reaches split' ;; esac
parent="$(tmux display-message -p -t "$pane" '#{@parent}')"
[ "$parent" = "$owner" ] || fail "split belongs to --for owner (got $parent, expected $owner)"
[ "$(tmux display-message -p -t "$pane" '#{@member}')" = 1 ] || fail 'member flag reaches split'
[ "$(tmux display-message -p -t "$pane" '#{pane_width}')" -gt 1 ] || fail 'split pane has a usable width'
[ "$(tmux display-message -p -t "$pane" '#{pane_left}')" -gt "$(tmux display-message -p -t %0 '#{pane_left}')" ] || fail '--right split direction is honored'
[ ! -e "$tmp/expanded" ] || fail 'file text was interpreted as shell input'
ready=0
for ((i = 0; i < 80; i++)); do
  tmux capture-pane -p -J -S -100 -t "$owner" >"$tmp/screen"
  # shellcheck disable=SC2016
  if grep -Fq 'literal $HOME $(touch ' "$tmp/screen" && grep -Fq 'second line' "$tmp/screen"; then ready=1; break; fi
  sleep 0.05
done
[ "$ready" = 1 ] || { cat "$tmp/screen" >&2; fail 'literal multiline file task reaches spawned agent'; }
if grep -Fq 'ignored task stdin payload' "$tmp/screen"; then fail 'stdin is ignored when a task file is supplied'; fi

reject() {
  if TMUX_PANE=%0 "$B/tmux-spawn" codex "$@" </dev/null >"$tmp/error" 2>&1; then return 1; fi
}
reject --message-file "$file" --name positional task || fail 'positional task conflicts'
grep -q 'conflicts with positional task text' "$tmp/error" || fail 'positional conflict error is clear'
reject --message-file "$file" --name empty-arg '' || fail 'empty positional task conflicts'
grep -q 'conflicts with positional task text' "$tmp/error" || fail 'empty positional conflict error is clear'
reject --message-file "$file" --message-file "$file" --name duplicate || fail 'duplicate file option rejected'
reject --message-file "$tmp/missing" --name missing || fail 'missing file rejected'
mkdir "$tmp/directory"
reject --message-file "$tmp/directory" --name directory || fail 'non-regular file rejected'
ln -s "$file" "$tmp/link"
reject --message-file "$tmp/link" --name symlink || fail 'symlink rejected'
chmod 000 "$file"
if [ "$(id -u)" -ne 0 ]; then reject --message-file "$file" --name unreadable || fail 'unreadable file rejected'; fi
chmod 600 "$file"
head -c 1048577 /dev/zero | tr '\000' x >"$tmp/large"
reject --message-file "$tmp/large" --name oversize || fail 'oversize file rejected'
reject --message-file "$file" --resume main || fail 'resume cannot use message file'
reject --message-file "$file" --list-closed || fail 'list-closed cannot use message file'
: >"$tmp/empty"
empty_out="$(TMUX_PANE=%0 "$B/tmux-spawn" codex --message-file "$tmp/empty" --name empty-file </dev/null)"
printf '%s\n' "$empty_out" | grep -q '^spawned codex ' || fail 'empty file follows no-task behavior'
tmux list-panes -a -F '#{@agent}' | grep -q -- '-empty-file$' || fail 'empty file starts a no-task agent'
printf 'ok: spawn message-file content, modes and validation\n'
