#!/usr/bin/env bash
# Settings precedence, safe cached decoding, and list/chip/preview consumers.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-settings-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-settings.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_LIST_CLIENT
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
count=0 failures=0
check() { local label="$1"; shift; count=$((count+1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; failures=$((failures+1)); fi; }
contains() { grep -Fq -- "$2" "$1"; }
absent() { ! contains "$@"; }
# Check every public mapping in fresh processes, preserving no prior cache.
while read -r key env default sample; do
  [ "$env" = - ] || unset "$env"
  tmux set -gu "@tmux_agents_$key" 2>/dev/null || true
  value="$(/bin/bash -c '. "$1"; settings_get result "$2" "$3" "$4"; printf %s "$result"' settings "$B/lib.sh" "${env/-/}" "@tmux_agents_$key" "${default/NONE/}")"
  check "$key default" test "$value" = "${default/NONE/}"
  tmux set -g "@tmux_agents_$key" "$sample"
  value="$(/bin/bash -c '. "$1"; settings_get result "$2" "$3" "$4"; printf %s "$result"' settings "$B/lib.sh" "${env/-/}" "@tmux_agents_$key" "${default/NONE/}")"
  check "$key option" test "$value" = "$sample"
  if [ "$env" != - ]; then
    value="$(env "$env=override" /bin/bash -c '. "$1"; settings_get result "$2" "$3" "$4"; printf %s "$result"' settings "$B/lib.sh" "$env" "@tmux_agents_$key" "${default/NONE/}")"
    check "$key environment wins" test "$value" = override
  fi
  tmux set -gu "@tmux_agents_$key"
done <<'MAP'
name_format TMUX_AGENTS_NAME_FORMAT prefixed exact
max_depth TMUX_AGENTS_MAX_DEPTH 2 4
codex_homes TMUX_AGENTS_CODEX_HOMES NONE work=/tmp/home
session_prefix TMUX_AGENTS_PREFIX agents helpers
resume_days TMUX_AGENTS_RESUME_DAYS 7 3
preview_secs TMUX_AGENTS_PREVIEW_SECS 0.5 0.25
blink_secs TMUX_AGENTS_BLINK_SECS 60 120
chip_fps - 10 1
ask_idle_secs TMUX_ASK_IDLE_SECS 8 2
ask_copy_idle_secs TMUX_ASK_COPY_IDLE_SECS 300 0
ask_queue_secs TMUX_ASK_QUEUE_SECS 1800 4
ask_max_lines TMUX_ASK_MAX_LINES 60 10
ask_enter_delay TMUX_ASK_ENTER_DELAY 0.5 0.01
connect_highlight TMUX_CONNECT_HIGHLIGHT bg=colour24 bg=colour27
MAP
# Quotes, spaces, shell substitutions and newlines must stay data, not code.
tricky=$'one="two words" literal=$(touch NEVER) slash=\\\nnext\tline'
tmux set -g @tmux_agents_codex_homes "$tricky"
export SETTINGS_REAL_TMUX="$(command -v tmux)" SETTINGS_CALLS="$tmp/calls"
/bin/bash -c '
  tmux() { [ "$*" != "show-options -g" ] || printf "snapshot\n" >>"$SETTINGS_CALLS"; "$SETTINGS_REAL_TMUX" "$@"; }
  . "$1"
  settings_get first "" @tmux_agents_codex_homes ""
  settings_get second "" @tmux_agents_codex_homes ""
  settings_get third "" @tmux_agents_blink_secs 60
  printf %s "$first" >"$2"
  test "$first" = "$second"
' settings "$B/lib.sh" "$tmp/decoded"
printf %s "$tricky" >"$tmp/expected"
check 'quoted values decoded as data' cmp -s "$tmp/expected" "$tmp/decoded"
check 'multiple reads use one option snapshot' test "$(wc -l <"$tmp/calls" | tr -d ' ')" = 1
tmux set -gu @tmux_agents_codex_homes
# Consumers: changing options must affect real rendered output.
tmux set -p -t %0 @agent main
child="$(tmux new-window -d -t work -c "$tmp" -P -F '#{pane_id}' /bin/cat)"
tmux set -p -t "$child" @agent child
tmux set -p -t "$child" @parent %0
tmux set -p -t "$child" @state needs_you
tmux set -p -t "$child" @attention_since "$(( $(date +%s) - 120 ))"
tmux set -g @tmux_agents_blink_secs 999
"$B/tmux-agents" --chip >"$tmp/chip"
check 'chip reads blink option' absent "$tmp/chip" ',blink'
TMUX_AGENTS_BLINK_SECS=0 "$B/tmux-agents" --chip >"$tmp/chip"
check 'chip environment overrides option' contains "$tmp/chip" ',blink'
tmux set -gu @tmux_agents_blink_secs
"$B/tmux-agents" --chip >"$tmp/chip"
check 'chip retains default blink threshold' contains "$tmp/chip" ',blink'
records="$XDG_STATE_HOME/tmux-agents/${S##*/}/sessions"
mkdir -p "$records"
. "$B/lib.sh"
ensure_agent_ids "$tmp/queue"
main_id="$(pane_agent_id %0)"
record() { printf 'agent_id=a000000000001\nname=saved\nkind=codex\nid=saved-id\ndir=%s\nparent=%s\nclosed=%s\n' "$tmp" "$main_id" "$(( $(date +%s)-172800 ))" >"$records/a000000000001"; }
record
tmux set -g @tmux_agents_resume_days 1
"$B/tmux-agents" --list >"$tmp/list"
check 'list applies option retention' test ! -e "$records/a000000000001"
record
TMUX_AGENTS_RESUME_DAYS=3 "$B/tmux-agents" --list >"$tmp/list"
check 'list retention env override' contains "$tmp/list" 'saved'
tmux set -gu @tmux_agents_resume_days
"$B/tmux-agents" --list >"$tmp/list"
check 'list retention default remains seven days' contains "$tmp/list" 'saved'
tmux set -g @tmux_agents_session_prefix helpers
value="$(/bin/bash -c '. "$1"; agents_session_for "$HOME"' settings "$B/lib.sh")"
check 'session helper reads prefix option' test "$value" = helpers-home
value="$(TMUX_AGENTS_PREFIX=override /bin/bash -c '. "$1"; agents_session_for "$HOME"' settings "$B/lib.sh")"
check 'session helper prefix env override' test "$value" = override-home
tmux set -gu @tmux_agents_session_prefix
tmux set -g @tmux_agents_chip_fps 1
"$B/tmux-agents" --chip-layout on
value="$(tmux show -gv 'status-format[0]')"
check 'one FPS option selects command-rendered chip' test "$value" = "#($B/tmux-agents --chip)"
"$B/tmux-agents" --chip-layout off
# One deterministic preview iteration; inspect the requested delay, never sleep.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'STUB'
#!/bin/sh
[ ! -f "$SETTINGS_PREVIEW_ONCE" ] || exit 1
: >"$SETTINGS_PREVIEW_ONCE"
STUB
cat >"$tmp/bin/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >"$SETTINGS_SLEEP"
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"
export SETTINGS_PREVIEW_ONCE="$tmp/once" SETTINGS_SLEEP="$tmp/sleep" FZF_PORT=1
tmux set -g @tmux_agents_preview_secs 0.125
PATH="$tmp/bin:$PATH" "$B/tmux-agents" --preview-loop
check 'preview interval option' test "$(cat "$tmp/sleep")" = 0.125
rm "$tmp/once"
TMUX_AGENTS_PREVIEW_SECS=0.25 PATH="$tmp/bin:$PATH" "$B/tmux-agents" --preview-loop
check 'preview interval env override' test "$(cat "$tmp/sleep")" = 0.25
printf '%s checks; failures=%s\n' "$count" "$failures"
[ "$failures" = 0 ]
