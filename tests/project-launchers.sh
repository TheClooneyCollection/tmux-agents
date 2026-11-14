#!/usr/bin/env bash
# Shared config, session windows, picker, save/edit and named-socket isolation.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-projects-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-project-launchers.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
mkdir -p "$tmp/bin" "$tmp/home/.config/tmux-main-sequence" "$tmp/alpha" "$tmp/two words" "$tmp/scan/one/.git" "$tmp/scan/group/two/.git" "$tmp/scan/one/nested/.git" "$tmp/scan/tree" "$tmp/home/Source/Projects/implicit/.git"
printf 'gitdir: x\n' > "$tmp/scan/tree/.git"
for kind in claude codex; do
  cat > "$tmp/bin/$kind" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\0' "$@" > "$TEST_LOG/$TMUX_PANE.args"
exec cat
STUB
  chmod +x "$tmp/bin/$kind"
done
cat > "$tmp/bin/fzf" <<'STUB'
#!/usr/bin/env bash
filter=''
while [ $# -gt 0 ]; do
  if [ "$1" = --filter ]; then filter="$2"; shift; fi
  shift
done
cat > "$TEST_LOG/choices"
grep -F -m 1 -- "$filter" "$TEST_LOG/choices"
STUB
chmod +x "$tmp/bin/fzf"
unset TMUX TMUX_PANE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH CLAUDECODE
unset TMUX_MAIN_SEQUENCE_SESSION TMUX_MAIN_SEQUENCE_CONFIG TMUX_MAIN_SEQUENCE_AGENT TMUX_CHAIN_SCAN_ROOT
unset TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state"
export TEST_LOG="$tmp" TMUX_SPAWN_BIN="$tmp/bin" PATH="$tmp/bin:$PATH"
export TMUX_MAIN_SEQUENCE_SOCKET="$sock"
tmux -L "$sock" -f /dev/null new-session -d -s test cat
tmux -L "$sock" has-session || exit 1
socket="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$socket" in ''|*/default) echo unsafe >&2; exit 1 ;; esac
export TMUX="$socket,1,0"
tmux -L "$sock" set -g default-shell /bin/sh
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
wait_file() { local i; for ((i=0;i<200;i++)); do [ ! -s "$1" ] || return 0; sleep .05; done; return 1; }
# With no file, there are no implicit home/blog windows or session.
"$B/tmux-agents" main-sequence --no-attach 2> "$tmp/empty"
if tmux has-session -t =main 2>/dev/null; then exit 1; fi
grep -q 'no configured projects' "$tmp/empty"
echo 'PASS empty configuration creates no built-in windows or session'
config="$HOME/.config/tmux-main-sequence/projects"
cat > "$config" <<CFG
# keep this comment
~ name=dashboard shell
~ name=home
"$tmp/two words" name=space shell # keep inline
$tmp/alpha name=alpha ignored-field
CFG
"$B/tmux-agents" main-sequence --no-attach 2> "$tmp/warn"
grep -q "unknown field 'ignored-field'" "$tmp/warn"
[ "$(tmux list-windows -t =main -F '#{window_index}:#{window_name}')" = $'0:dashboard\n1:home\n2:space\n3:alpha' ]
[ "$(tmux list-sessions -F '#{session_name}' | grep -c '^main')" = 1 ]
for target in main:1 main:3; do
  pane="$(tmux display -p -t "$target" '#{pane_id}')"
  wait_file "$tmp/$pane.args"
  tmux capture-pane -p -t "$pane" | grep -q 'FAKE claude'
done
for target in main:0 main:2; do
  [ -z "$(tmux display -p -t "$target" '#{@agent_id}')" ]
done
echo 'PASS legacy fallback, config order, names, duplicate directories and shell windows'
"$B/tmux-agents" main-sequence --no-attach
[ "$(tmux list-windows -t =main | wc -l | tr -d ' ')" = 4 ]
if "$B/tmux-agents" main-sequence set '~' resume=abc > "$tmp/out" 2> "$tmp/error"; then exit 1; fi
grep -q 'ambiguous project' "$tmp/error"
grep -q 'line 2:' "$tmp/error"
grep -q 'line 3:' "$tmp/error"
"$B/tmux-agents" main-sequence set home resume=11111111-1111-4111-8111-111111111111 > "$tmp/out" 2>/dev/null
grep -q '^~ name=home resume=' "$tmp/out"
new_config="$XDG_CONFIG_HOME/tmux-agents/projects"
[ -f "$new_config" ]
if grep -q 'resume=' "$config"; then exit 1; fi
grep -q '^# keep this comment' "$new_config"
grep -q '# keep inline' "$new_config"
"$B/tmux-agents" main-sequence unset home resume > "$tmp/out" 2>/dev/null
[ "$(cat "$tmp/out")" = '~ name=home' ]
cmp "$config" "$new_config"
echo 'PASS ambiguous edit candidates, targeted set/unset, comments and fallback migration'
printf '%s name=later shell\n' "$tmp/alpha" >> "$new_config"
"$B/tmux-agents" main-sequence --no-attach 2>/dev/null
[ "$(tmux list-windows -t =main | wc -l | tr -d ' ')" = 4 ]
"$B/tmux-agents" main-sequence --add-missing --no-attach 2>/dev/null
[ "$(tmux display -p -t main:4 '#{window_name}')" = later ]
echo 'PASS existing sessions unchanged until --add-missing'
# Environment session/config overrides option; Codex resume goes through start chain.
id=22222222-2222-4222-8222-222222222222
export CODEX_HOME="$tmp/codex"
mkdir -p "$CODEX_HOME/sessions"
printf '{}\n' > "$CODEX_HOME/sessions/rollout-test-$id.jsonl"
printf '%s name=continued resume=%s\n' "$tmp/alpha" "$id" > "$tmp/override"
tmux set -g @tmux_agents_main_sequence_session option-session
tmux set -g @tmux_agents_projects_config "$tmp/not-selected"
TMUX_MAIN_SEQUENCE_CONFIG="$tmp/override" TMUX_MAIN_SEQUENCE_SESSION=chosen TMUX_AGENTS_CHAIN_MAIN=codex "$B/tmux-agents" main-sequence --no-attach
pane="$(tmux display -p -t chosen:0 '#{pane_id}')"
wait_file "$tmp/$pane.args"
python3 - "$tmp/$pane.args" "$id" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[0]==b'resume' and args[-2]==sys.argv[2].encode(),args
PY
if tmux has-session -t =option-session 2>/dev/null; then exit 1; fi
echo 'PASS session/config env precedence and resume pass-through'
tmux set -gu @tmux_agents_projects_config
tmux set -gu @tmux_agents_main_sequence_session
# Picker includes field-carrying paths and default current directory, no implicit scan.
"$B/tmux-agents" chain --filter 'two words' --no-save --target test --name picked > "$tmp/pane" 2>/dev/null
pane="$(cat "$tmp/pane")"
[ "$(tmux display -p -t "$pane" '#{window_name}')" = picked ]
grep -Fxq "$PWD" "$tmp/choices"
grep -Fxq "$tmp/two words" "$tmp/choices"
if grep -q implicit "$tmp/choices"; then exit 1; fi
if grep -q "$tmp/scan" "$tmp/choices"; then exit 1; fi
"$B/tmux-agents" chain --filter no-such-project --target test > "$tmp/pane" 2>/dev/null
[ ! -s "$tmp/pane" ]
TMUX_CHAIN_SCAN_ROOT="$tmp/scan" "$B/tmux-agents" chain --filter "$tmp/scan/one" --no-save --target test > "$tmp/pane" 2>/dev/null
grep -Fxq "$tmp/scan/one" "$tmp/choices"
grep -Fxq "$tmp/scan/group/two" "$tmp/choices"
if grep -q nested "$tmp/choices"; then exit 1; fi
if grep -Fxq "$tmp/scan/tree" "$tmp/choices"; then exit 1; fi
tmux set -g @tmux_agents_chain_scan_root "$tmp/scan"
"$B/tmux-agents" chain --include-worktrees --filter "$tmp/scan/tree" --no-save --target test > "$tmp/pane" 2>/dev/null
grep -Fxq "$tmp/scan/tree" "$tmp/choices"
echo 'PASS picker fields, cancellation, no default scan, env/option scan and worktrees'
cp "$new_config" "$tmp/before"
"$B/tmux-agents" chain "$tmp/alpha" --save --target test > /dev/null 2>/dev/null
cmp "$new_config" "$tmp/before"
mkdir -p "$tmp/new project"
"$B/tmux-agents" chain "$tmp/new project" --no-save --save --target test > /dev/null 2>/dev/null
grep -q "'$tmp/new project'" "$new_config"
"$B/tmux-agents" chain "$tmp/new project" --save --target test > /dev/null 2>/dev/null
[ "$(grep -c 'new project' "$new_config")" = 1 ]
echo 'PASS save deduplicates parsed directories and quotes paths'
TMUX_MAIN_SEQUENCE_AGENT='printf CUSTOM; exec cat' "$B/tmux-agents" chain "$tmp/alpha" --no-save --target test > "$tmp/pane"
pane="$(cat "$tmp/pane")"
for ((i=0;i<100;i++)); do
  if tmux capture-pane -p -t "$pane" | grep -q CUSTOM; then break; fi
  sleep .05
done
tmux capture-pane -p -t "$pane" | grep -q CUSTOM
echo 'PASS custom agent command override'
"$B/tmux-agents" --help | grep -q main-sequence

cp "$new_config" "$tmp/pre-add"
"$B/tmux-agents" main-sequence add "$tmp/alpha" name=appended shell > "$tmp/added" 2>/dev/null
"$B/tmux-agents" main-sequence list > "$tmp/list" 2>/dev/null
cmp "$new_config" "$tmp/list"
[ "$(tail -1 "$tmp/list")" = "$tmp/alpha name=appended shell" ]
head -n "$(wc -l < "$tmp/pre-add" | tr -d ' ')" "$tmp/list" > "$tmp/prefix"
cmp "$tmp/pre-add" "$tmp/prefix"
"$B/tmux-agents" main-sequence add "$tmp/alpha" name=inserted shell --at 2 > "$tmp/added" 2>/dev/null
[ "$(sed -n '3p' "$new_config")" = "$tmp/alpha name=inserted shell" ]
sed '3d' "$new_config" > "$tmp/without-insert"
cmp "$tmp/list" "$tmp/without-insert"
cp "$new_config" "$tmp/unchanged"
if "$B/tmux-agents" main-sequence add "$tmp/alpha" --at 999 2>/dev/null; then exit 1; fi
cmp "$new_config" "$tmp/unchanged"
echo 'PASS append, 1-based insertion, list and preservation of existing lines/comments'
