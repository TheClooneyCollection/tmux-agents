#!/usr/bin/env bash
# Orientation is read-only; handoff and note bodies are opt-in, peers use live state.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sock="tmux-status-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-status.XXXXXX")"
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
unset TMUX TMUX_PANE CLAUDECODE
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_PINNED=1
mkdir -p "$tmp/bin" "$tmp/project"
for agent in claude codex; do
  printf '#!/bin/sh\necho stub-agent\nexec cat\n' > "$tmp/bin/$agent"
  chmod +x "$tmp/bin/$agent"
done
export TMUX_SPAWN_BIN="$tmp/bin"
git -C "$tmp/project" init -q
printf 'HANDOFF.md\n' > "$tmp/project/.git/info/exclude"
printf 'PRIVATE HANDOFF BODY\n' > "$tmp/project/HANDOFF.md"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project" "$tmp/bin/claude"
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || exit 1
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
wait_marker() {
  local pane="$1" attempt
  for ((attempt=0; attempt<100; attempt++)); do
    tmux capture-pane -p -t "$pane" > "$tmp/screen"
    if grep -q stub-agent "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  echo "stub marker missing in $pane" >&2; cat "$tmp/screen" >&2; return 1
}
wait_marker %0
tmux set-option -p -t %0 @agent claude-project-main
tmux set-option -p -t %0 @agent_id a000000000001
tmux set-option -p -t %0 @tracked 1
tmux set-option -p -t %0 @state idle
tmux split-window -d -t %0 "$tmp/bin/codex"
wait_marker %1
tmux set-option -p -t %1 @agent codex-project-secondary
tmux set-option -p -t %1 @agent_id a000000000002
tmux set-option -p -t %1 @parent %0
tmux set-option -p -t %1 @tracked 1
tmux set-option -p -t %1 @state working
tmux set-option -p -t %1 @state_since 123
tmux set-option -p -t %0 @peers '%1 %999'
tmux set-option -p -t %1 @peers %0
cd "$tmp/project"
run() { "$here/bin/tmux-agents" status "$@"; }
mission() { "$here/bin/tmux-agents" mission "$@" --from claude-project-main; }
mission add 'My mission' > /dev/null
mission log M1 'old log'
mission log M1 'recent log 1'
mission log M1 'recent log 2'
mission log M1 'recent log 3'
mission add 'Completed mission' --status 'done' > /dev/null
mkdir -p "$XDG_STATE_HOME/tmux-agents/$sock/sessions"
printf 'kind=codex-profile\n' > "$XDG_STATE_HOME/tmux-agents/$sock/sessions/a000000000002"
notes_dir="$XDG_STATE_HOME/tmux-agents/$sock/notes/a000000000001"
mkdir -p "$notes_dir"
printf '0\n' > "$notes_dir/.cursor"
printf '1\n' > "$notes_dir/.sequence"
printf '{"id":1,"at":%s,"from_name":"worker","message_id":"maabb","text":"PRIVATE NOTE BODY"}\n' "$(date +%s)" > "$notes_dir/00000000000000000001-maabb.json"
# Read-only includes filesystem content and tmux options, including stale peers.
find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort > "$tmp/before"
tmux show-options -p -t %0 > "$tmp/options-before"
run > "$tmp/out"
grep -q '^you: claude-project-main (%0) role=main parent=- depth=0' "$tmp/out"
grep -q 'waiting on codex-project-secondary' "$tmp/out"
grep -q '^roles:' "$tmp/out"
grep -q 'My mission' "$tmp/out"
grep -q 'recent log 1' "$tmp/out"
if grep -Eq 'old log|Completed mission|PRIVATE' "$tmp/out"; then cat "$tmp/out"; exit 1; fi
grep -q 'notes: 1 unread; worker (1)' "$tmp/out"
grep -q 'HANDOFF.md: present, untracked, ignored (1 lines)' "$tmp/out"
find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
tmux show-options -p -t %0 > "$tmp/options-after"
cmp "$tmp/options-before" "$tmp/options-after"
"$here/bin/tmux-agents" resume > "$tmp/resume"
cmp "$tmp/out" "$tmp/resume"
run --handoff --missions full > "$tmp/out"
grep -q 'PRIVATE HANDOFF BODY' "$tmp/out"
grep -q 'Completed mission' "$tmp/out"
run codex-project-secondary > "$tmp/out"
grep -q 'role=interface parent=%0 depth=1' "$tmp/out"
tmux set-option -p -t %1 @role reviewer
run codex-project-secondary > "$tmp/out"
grep -q 'role=reviewer' "$tmp/out"
grep -q 'kind=codex-profile' "$tmp/out"
run --notes > "$tmp/out"
grep -q 'PRIVATE NOTE BODY' "$tmp/out"
run > "$tmp/out"
if grep -q 'notes:' "$tmp/out"; then exit 1; fi
if TMUX_AGENTS_PINNED='' run > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
TMUX_AGENTS_PINNED='' run --from claude-project-main > "$tmp/out"
[ "$("$here/bin/tmux-peers" --me)" = claude-project-main ]
if TMUX_AGENTS_PINNED='' "$here/bin/tmux-peers" --me > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run unknown > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run --missions invalid > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
# Track handoff deliberately to verify the warning while preserving opt-in body.
git add -f HANDOFF.md
run > "$tmp/out"
grep -q 'HANDOFF.md: WARNING: tracked' "$tmp/out"
if grep -q PRIVATE "$tmp/out"; then exit 1; fi
# Legacy pane names are literal, even when they contain awk escape sequences.
caller='claude-project-\name'
peer='codex-project-\target'
tmux set-option -p -t %0 @agent "$caller"
tmux set-option -p -t %1 @agent "$peer"
"$here/bin/tmux-agents" mission add Literal --from "$caller" > /dev/null
"$here/bin/tmux-agents" mission log M3 'literal owner log' --from "$caller"
run --from "$caller" > "$tmp/out"
grep -Fq "you: $caller" "$tmp/out"
grep -q 'literal owner log' "$tmp/out"
run --from "$caller" "$peer" > "$tmp/out"
grep -Fq "peer: $peer" "$tmp/out"
echo 'ok status read-only snapshot, roles, logs, notes, handoff and alias'
