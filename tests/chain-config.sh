#!/usr/bin/env bash
# Read-only chain role resolution, precedence, validation and unavailable sockets.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-chain-config-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-chain-config.XXXXXX")"
unset TMUX TMUX_PANE TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER TMUX_AGENTS_CODEX_HOMES
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT trap.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
query() { "$B/tmux-agents" chain-config "$@"; }
# Invoked by check.
# shellcheck disable=SC2329
reject() {
  if query "$@" >"$tmp/out" 2>"$tmp/err"; then return 1; fi
  test ! -s "$tmp/out" && test -s "$tmp/err"
}
# A tmux sentinel proves no-session queries never contact the default server.
mkdir -p "$tmp/no-server"
cat >"$tmp/no-server/tmux" <<'STUB'
#!/bin/sh
printf 'unexpected tmux call\n' >>"$CHAIN_TMUX_CALLS"
exit 1
STUB
chmod +x "$tmp/no-server/tmux"
export CHAIN_TMUX_CALLS="$tmp/tmux-calls"
check 'no-session never consults default server' test "$(PATH="$tmp/no-server:$PATH" query main)" = claude
check 'no-session makes no tmux calls' test ! -e "$CHAIN_TMUX_CALLS"
check 'no-session defaults in fixed TSV order' test "$(query)" = $'main\tclaude\ndesigner\tclaude\ninterface\tclaude\nworker\tcodex\nreviewer\tclaude\nrunner\tclaude\nresearcher\tclaude'
check 'no-session default sources' test "$(query --sources)" = $'main\tclaude\tdefault\ndesigner\tclaude\tdefault\ninterface\tclaude\tdefault\nworker\tcodex\tdefault\nreviewer\tclaude\tdefault\nrunner\tclaude\tdefault\nresearcher\tclaude\tdefault'
check 'no-session env works' test "$(TMUX_AGENTS_CHAIN_MAIN=codex query main --sources)" = $'main\tcodex\tenv'
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp" /bin/cat
tmux -L "$sock" set -g default-shell /bin/sh
tmux -L "$sock" has-session || { echo 'ABORT: test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
before="$(tmux list-panes -a -F '#{pane_id} #{@agent} #{@agent_id} #{@tracked}')"
for role in main interface worker; do
  case "$role" in main) role_env=TMUX_AGENTS_CHAIN_MAIN; default=claude ;; interface) role_env=TMUX_AGENTS_CHAIN_SECONDARY; default=claude ;; worker) role_env=TMUX_AGENTS_CHAIN_WORKER; default=codex ;; esac
  check "$role scalar default" test "$(query "$role")" = "$default"
  tmux set -g "@tmux_agents_chain_$role" codex
  check "$role option source" test "$(query "$role" --sources)" = "$(printf '%s\tcodex\toption' "$role")"
  check "$role env beats option" test "$(env "$role_env=claude" "$B/tmux-agents" chain-config "$role" --sources)" = "$(printf '%s\tclaude\tenv' "$role")"
  check "$role explicit beats env" test "$(env "$role_env=claude" "$B/tmux-agents" chain-config "$role" "--$role" codex --sources)" = "$(printf '%s\tcodex\texplicit' "$role")"
  check "$role empty env falls back" test "$(env "$role_env=" "$B/tmux-agents" chain-config "$role" --sources)" = "$(printf '%s\tcodex\toption' "$role")"
  tmux set -g "@tmux_agents_chain_$role" ''
  check "$role empty option falls back" test "$(query "$role" --sources)" = "$(printf '%s\t%s\tdefault' "$role" "$default")"
  tmux set -gu "@tmux_agents_chain_$role"
  tmux set-environment -g "$role_env" codex
  check "$role ignores legacy server environment" test "$(query "$role" --sources)" = "$(printf '%s\t%s\tdefault' "$role" "$default")"
  tmux set-environment -gu "$role_env"
  check "$role duplicate flag rejected without output" reject "--$role" codex "--$role" claude
  check "$role explicit empty rejected without output" reject "--$role" ''
  check "$role missing flag value rejected" reject "--$role"
  check "$role unknown kind rejected" reject "--$role" unknown-agent
  check "$role non-codex profile preserved" test "$(TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile" query "$role" "--$role" extra)" = extra
done
check 'defaults include args in fixed order' test "$(query --args)" = $'main\tclaude\t-\ndesigner\tclaude\t-\ninterface\tclaude\t--model sonnet\nworker\tcodex\t-\nreviewer\tclaude\t-\nrunner\tclaude\t--model haiku\nresearcher\tclaude\t--model sonnet'
check 'reviewer environment selects chain agent' test "$(TMUX_AGENTS_CHAIN_REVIEWER=codex query reviewer)" = codex
check 'secondary query canonical row' test "$(query secondary --args --sources)" = $'interface\tclaude\t--model sonnet\tdefault'
check 'alias duplicate rejected' reject --secondary claude --interface codex
check 'reverse alias duplicate rejected' reject --interface codex --secondary claude
check 'duplicate args rejected' reject --args --args
for role in designer reviewer runner researcher; do
  tmux set -g "@tmux_agents_chain_$role" codex
  check "$role option overrides and drops default args" test "$(query "$role" --args --sources)" = "$(printf '%s\tcodex\t-\toption' "$role")"
  tmux set -g "@tmux_agents_chain_${role}_args" '--model custom'
  check "$role explicit args survive agent override" test "$(query "$role" --args)" = "$(printf '%s\tcodex\t--model custom' "$role")"
  tmux set -gu "@tmux_agents_chain_$role"
  tmux set -gu "@tmux_agents_chain_${role}_args"
done
tmux set -g @tmux_agents_chain_secondary codex
check 'legacy secondary option fallback' test "$(query interface --sources)" = $'interface\tcodex\toption'
tmux set -g @tmux_agents_chain_interface claude
check 'interface option wins over alias' test "$(query secondary)" = claude
check 'secondary env wins over interface option' test "$(TMUX_AGENTS_CHAIN_SECONDARY=codex query interface)" = codex
tmux set -g @tmux_agents_chain_secondary_args '--model legacy'
check 'legacy args fallback' test "$(query interface --args)" = $'interface\tclaude\t--model legacy'
tmux set -g @tmux_agents_chain_interface_args none
check 'none clears args and wins over alias' test "$(query interface --args)" = $'interface\tclaude\t-'
# Literal escapes and quoted values survive tmux's output encoding unchanged.
for literal in 'back\slash' 'literal\tword' '--model "custom"' "single'quote"; do
  tmux set -g @tmux_agents_chain_interface_args "$literal"
  check "literal option survives: $literal" test "$(query interface --args)" = "$(printf 'interface\tclaude\t%s' "$literal")"
done
for invalid in $'--model\tbad' $'--model\nbad' $'--model\rbad'; do
  tmux set -g @tmux_agents_chain_interface_args "$invalid"
  check 'control character args rejected without output' reject --args
done
for option in interface secondary interface_args secondary_args; do tmux set -gu "@tmux_agents_chain_$option"; done
check 'unknown role rejected' reject observer
check 'duplicate role rejected' reject main main
check 'two roles rejected' reject main worker
check 'unknown option rejected' reject --unknown
check 'duplicate sources flag rejected' reject --sources --sources
check 'selected role ignores invalid other explicit value' test "$(query main --worker missing)" = claude
check 'selected role ignores invalid other setting' test "$(TMUX_AGENTS_CHAIN_WORKER=missing query main)" = claude
if TMUX_AGENTS_CHAIN_WORKER=missing query >"$tmp/out" 2>"$tmp/err"; then check 'invalid last setting fails' false; fi
check 'invalid last setting has empty stdout' test ! -s "$tmp/out"
# Expanded by the child shell.
# shellcheck disable=SC2016
check 'invalid setting reports role value and source' bash -c 'grep -q worker "$1" && grep -q missing "$1" && grep -q env "$1"' _ "$tmp/err"
# Shell syntax in a role is data and must never run.
malicious="\$(touch $tmp/EXECUTED)"
check 'shell expression rejected as data' reject --main "$malicious"
check 'shell expression was not evaluated' test ! -e "$tmp/EXECUTED"
check 'query leaves pane identity and tracking untouched' test "$(tmux list-panes -a -F '#{pane_id} #{@agent} #{@agent_id} #{@tracked}')" = "$before"
check 'query creates no state directory' test ! -e "$XDG_STATE_HOME/tmux-agents"
if TMUX="$tmp/missing-socket,1,0" query >"$tmp/out" 2>"$tmp/err"; then check 'inaccessible socket fails' false; fi
check 'inaccessible socket has no stdout' test ! -s "$tmp/out"
check 'inaccessible socket explains failure' test -s "$tmp/err"
exit "$fail"
