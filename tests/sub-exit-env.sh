#!/usr/bin/env bash
# Actual returned split/chain shells preserve environment; agents retain launch pins.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-exit-env-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-exit-env.XXXXXX")"
mkdir -p "$tmp/bin" "$tmp/profile"
keys='CODEX_HOME TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER TMUX_AGENTS_CODEX_HOMES CLAUDECODE TMUX_SPAWN_BIN TMUX_AGENTS_SUB_AUTO'
cat > "$tmp/dump" <<'PERL'
use strict;
use warnings;
open my $out, '>', $ARGV[0] or die $!;
for my $key (qw(CODEX_HOME PATH TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER TMUX_AGENTS_CODEX_HOMES CLAUDECODE TMUX_SPAWN_BIN TMUX_AGENTS_SUB_AUTO)) {
    print $out "$key:", exists $ENV{$key} ? "set:$ENV{$key}" : 'unset', "\n";
}
close $out or die $!;
PERL
for a in claude codex; do
  cat > "$tmp/bin/$a" <<'STUB'
#!/bin/sh
/usr/bin/perl "$EXIT_ENV_TMP/dump" "$EXIT_ENV_TMP/agent-${TMUX_PANE#%}"
printf '%s\n' "$@" > "$EXIT_ENV_TMP/args-${TMUX_PANE#%}"
echo "FAKE $(basename "$0")"
exec cat
STUB
  chmod +x "$tmp/bin/$a"
done
unset TMUX TMUX_PANE
for key in $keys; do unset "$key"; done
export TMUX_AGENTS_SUB_AUTO=on
export XDG_STATE_HOME="$tmp/state" TMUX_SPAWN_BIN="$tmp/bin" EXIT_ENV_TMP="$tmp"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 70 cat
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; tmux -L "$sock" kill-server; exit 1 ;; esac
export TMUX="$S,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
. "$B/lib.sh"
set_name %0 main
tmux set -g @tmux_agents_codex_homes "profile=$tmp/profile"
# Preserve a deliberately unusual PATH exactly, including repeated entries.
base_path="$PATH:/bin:/bin"
export PATH="$base_path"
tmux set-environment -g PATH "$base_path"
tmux set-environment -t work PATH "$base_path"
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
# shellcheck disable=SC2329
path_matches() {
  if grep -Fxq "PATH:set:$1" "$2"; then return 0; fi
  printf 'expected PATH: %s\n' "$1"
  grep '^PATH:' "$2" || true
  return 1
}
# shellcheck disable=SC2329
wait_for() { local i; for ((i=0;i<200;i++)); do if "$@"; then return 0; fi; sleep .05; done; return 1; }
# shellcheck disable=SC2329
started() { tmux capture-pane -p -t "$1" | grep -q "FAKE $2"; }
# shellcheck disable=SC2329
cleared() { [ -z "$(tmux show-options -pqv -t "$1" @agent_id)" ]; }
for state in unset set empty; do
  for key in $keys; do
    case "$state" in
      unset) tmux set-environment -gu "$key" ;;
      set) tmux set-environment -g "$key" "original $key ' value" ;;
      empty) tmux set-environment -g "$key" '' ;;
    esac
  done
  for mode in split chain; do
    if [ "$mode" = split ]; then
      TMUX_PANE=%0 "$B/tmux-spawn" profile --from main --exact --name "env-$state" --split main </dev/null > "$tmp/spawn"
      pane="$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="env-$state" '$2 == n {print $1}')"
      depth=1
    else
      pane="$(TMUX_PANE=%0 "$B/tmux-agents" start chain "$tmp" --main profile --secondary claude --worker codex)"
      depth=0
    fi
    check "$mode $state starts Codex stub" wait_for started "$pane" codex
    agent_dump="$tmp/agent-${pane#%}"
    check "$mode $state agent profile" grep -Fxq "CODEX_HOME:set:$tmp/profile" "$agent_dump"
    check "$mode $state agent launch PATH" path_matches "$tmp/bin:$B:$base_path" "$agent_dump"
    check "$mode $state agent depth pin" grep -Fq "shell_environment_policy.set.TMUX_AGENTS_DEPTH=\"$depth\"" "$tmp/args-${pane#%}"
    check "$mode $state agent identity pin" grep -Fq 'shell_environment_policy.set.TMUX_AGENTS_PINNED="1"' "$tmp/args-${pane#%}"
    check "$mode $state agent kind pin" grep -Fq 'shell_environment_policy.set.TMUX_AGENTS_KIND="profile"' "$tmp/args-${pane#%}"
    tmux send-keys -t "$pane" C-d
    check "$mode $state identity cleared" wait_for cleared "$pane"
    returned="$tmp/returned-${pane#%}"
    tmux send-keys -t "$pane" -l "/usr/bin/perl '$tmp/dump' '$returned'"
    tmux send-keys -t "$pane" Enter
    check "$mode $state returned shell executes" wait_for test -s "$returned"
    check "$mode $state exact returned PATH" path_matches "$base_path" "$returned"
    for key in $keys; do
      expected="$key:unset"
      case "$state" in
        set) expected="$key:set:original $key ' value" ;;
        empty) expected="$key:set:" ;;
      esac
      check "$mode $state returned $key" grep -Fxq "$expected" "$returned"
    done
    tmux kill-pane -t "$pane"
  done
done
[ "$fail" -ne 0 ] || echo 'all passed'
exit "$fail"
