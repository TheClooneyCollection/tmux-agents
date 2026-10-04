#!/usr/bin/env bash
# Given spawn names, format precedence and unchanged resume on an isolated server.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-spawn-names-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-spawn-names.XXXXXX")"
cleanup() { tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/project"
for a in claude codex; do
  printf '#!/bin/sh\nprintf "STUB READY %s FORMAT=%%s HOME=%%s HOMES=%%s\\n" "${TMUX_AGENTS_NAME_FORMAT-unset}" "${CODEX_HOME-unset}" "${TMUX_AGENTS_CODEX_HOMES-unset}"\nexec cat\n' "$a" >"$tmp/bin/$a"
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE CLAUDECODE CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_NAME_FORMAT
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" TMUX_ASK_ENTER_DELAY=0
export TMUX_AGENTS_CODEX_HOMES="extra=$tmp/codex-home"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 -c "$tmp/project" cat
tmux -L "$sock" has-session 2>/dev/null || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo "ABORT: unsafe socket '$S'"; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
# No personal shell startup files may run in spawned test panes.
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"
fail=0 count=0
check() { local label="$1"; shift; count=$((count + 1)); if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
pane_of() { tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n {print $1}'; }
spawn() { "$B/tmux-spawn" "$@" --from "${caller:-main}" </dev/null; }
reject() { if spawn "$@" >"$tmp/error" 2>&1; then return 1; else return 0; fi; }
ready() {
  local p="$1" kind="$2" i
  [ -n "$p" ] || return 1
  for i in {1..100}; do
    tmux capture-pane -p -J -t "$p" -S -100 >"$tmp/screen"
    if grep -q "STUB READY $kind " "$tmp/screen"; then return 0; fi
    sleep 0.05
  done
  return 1
}
expect_spawn() {
  local expected="$1" kind="$2"; shift 2
  spawn "$@" >"$tmp/spawn"
  check "prints $expected" grep -Fq " as $expected," "$tmp/spawn"
  spawned="$(pane_of "$expected")"
  check "$expected has the $kind stub" ready "$spawned" "$kind"
}
expect_spawn claude-project-review claude claude --name review
expect_spawn codex-project-build codex codex --name build
expect_spawn codex-project-profile codex extra --name profile
TMUX_AGENTS_KIND=claude expect_spawn codex-project-own-kind codex codex --name own-kind
TMUX_AGENTS_KIND=codex expect_spawn claude-project-own-kind claude claude --name own-kind
TMUX_AGENTS_KIND=extra expect_spawn codex-project-inherited codex --name inherited
expect_spawn codex-project-existing codex codex --name codex-project-existing
expect_spawn codex-project-build-2 codex codex --name build
expect_spawn codex-project-build-3 codex codex --name build
expect_spawn codex-project-Auth-Review codex codex --name "Auth Review"
check "exact refuses spaces rather than sanitising" reject codex --name "Auth Review" --exact
expect_spawn raw codex codex --name raw --exact
expect_spawn raw-2 codex codex --exact --name raw
# Both option values, environment overrides and the unset-option default.
tmux set -g @tmux_agents_name_format exact
expect_spawn option-exact claude claude --name option-exact
TMUX_AGENTS_NAME_FORMAT=prefixed expect_spawn codex-project-env-prefixed codex codex --name env-prefixed
tmux set -g @tmux_agents_name_format prefixed
expect_spawn claude-project-option-prefixed claude claude --name option-prefixed
TMUX_AGENTS_NAME_FORMAT=exact expect_spawn env-exact codex codex --name env-exact
check 'invocation override is not forwarded to child' grep -Fq 'FORMAT=unset' "$tmp/screen"
TMUX_AGENTS_NAME_FORMAT=prefixed expect_spawn flag-wins claude claude --exact --name flag-wins
tmux set -gu @tmux_agents_name_format
TMUX_AGENTS_NAME_FORMAT=exact expect_spawn env-default codex codex --name env-default
expect_spawn codex-project-default codex codex --name default
# Depth reads the live option, with the invocation environment taking priority.
TMUX_AGENTS_DEPTH=2 check 'default depth limit is two' reject codex --name depth-default
tmux set -g @tmux_agents_max_depth 1
TMUX_AGENTS_DEPTH=1 check 'option lowers depth limit' reject codex --name depth-option
TMUX_AGENTS_DEPTH=1 TMUX_AGENTS_MAX_DEPTH=2 expect_spawn codex-project-depth-env codex codex --name depth-env
tmux set -g @tmux_agents_max_depth 3
TMUX_AGENTS_DEPTH=2 expect_spawn codex-project-depth-option codex codex --name depth-option
tmux set -gu @tmux_agents_max_depth
# Profiles resolve from the option before the legacy global environment.
unset TMUX_AGENTS_CODEX_HOMES
tmux set-environment -gu TMUX_AGENTS_CODEX_HOMES
tmux set -g @tmux_agents_codex_homes "work=$tmp/option-home"
expect_spawn codex-project-option-profile codex work --name option-profile
check 'option profile reaches the launched agent' grep -Fq "HOME=$tmp/option-home " "$tmp/screen"
check 'option profile is not exported as an override' test "$(grep -Fc "HOMES=work=$tmp/option-home" "$tmp/screen" || true)" = 0
TMUX_AGENTS_CODEX_HOMES="work=$tmp/env-home" expect_spawn codex-project-env-profile codex work --name env-profile
check 'environment profile wins and reaches the child' grep -Fq "HOME=$tmp/env-home HOMES=work=$tmp/env-home" "$tmp/screen"
tmux set-environment -g TMUX_AGENTS_CODEX_HOMES "work=$tmp/legacy-home"
expect_spawn codex-project-option-over-legacy codex work --name option-over-legacy
check 'option wins over legacy global environment' grep -Fq "HOME=$tmp/option-home " "$tmp/screen"
tmux set -gu @tmux_agents_codex_homes
expect_spawn codex-project-legacy-profile codex work --name legacy-profile
check 'legacy global environment remains a fallback' grep -Fq "HOME=$tmp/legacy-home " "$tmp/screen"
tmux set-environment -gu TMUX_AGENTS_CODEX_HOMES
# Home must use ~, based on the caller directory rather than this script's cwd.
home_pane="$(tmux new-window -d -t work -c "$HOME" -P -F '#{pane_id}' cat)"
tmux set -p -t "$home_pane" @agent home-parent
caller=home-parent expect_spawn 'claude-~-home' claude claude --name home
# Automatic names retain their existing format even with exact preference.
TMUX_AGENTS_NAME_FORMAT=exact expect_spawn codex-project-1 codex codex
FZF_PROMPT='agents · all windows> ' "$B/tmux-agents" --list | tr '\0' '\n' >"$tmp/list"
check 'prefixed agent is visible in list' grep -Fq 'codex-project-build' "$tmp/list"
check '--exact requires a given name' reject codex --exact
check '--name requires a value' reject codex --name ''
check 'resume rejects --exact' reject --resume claude-project-review --exact
check 'resume rejects --name' reject --resume claude-project-review --name replacement
"$B/tmux-dismiss" --from main claude-project-review >"$tmp/dismiss"
TMUX_AGENTS_NAME_FORMAT=exact spawn --resume claude-project-review >"$tmp/resume"
check 'resume keeps the original prefixed name' grep -Fq 'reopened claude-project-review (' "$tmp/resume"
check 'resumed prefixed agent runs stub' ready "$(pane_of claude-project-review)" claude
expect_spawn legacy claude claude --exact --name legacy
"$B/tmux-dismiss" --from main legacy >"$tmp/dismiss"
TMUX_AGENTS_NAME_FORMAT=prefixed spawn --resume legacy >"$tmp/resume"
check 'resume keeps legacy bare name under prefixed format' grep -Fq 'reopened legacy (' "$tmp/resume"
check 'resumed bare agent runs stub' ready "$(pane_of legacy)" claude
[ "$fail" -eq 0 ] && echo "all $count passed" || echo 'some failed'
exit "$fail"
