#!/usr/bin/env bash
# Receiver-aware request instructions, with isolated tmux.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-request-reply-mode-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-request-reply-mode.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state" TMUX_AGENTS_CODEX_HOMES="codex-2nd=$tmp/codex-home"
export TMUX_ASK_ENTER_DELAY=0 TMUX_ASK_COPY_IDLE_SECS=0
. "$here/tests/helpers/cleanup.sh"
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT

tmux -L "$sock" -f /dev/null new-session -d -s work -x 160 -y 50 cat
tmux -L "$sock" has-session || { echo 'ABORT: private test server unavailable'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe test socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent sender
. "$B/lib.sh"
ensure_agent_ids "$tmp/empty-queue"

fail() { echo "FAIL: $*" >&2; exit 1; }
count=0
check() {
  label="$1"; shift; count=$((count + 1))
  if "$@"; then echo "ok $count: $label"; else fail "$label"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
kind_for() { request_receiver_kind "$1"; }
targets=(claude codex codex-2nd tool)
kinds=(claude codex codex-2nd external-cli)
p=()
for i in "${!targets[@]}"; do
  p[i]="$(tmux new-window -d -P -F '#{pane_id}' cat)"
  tmux set-option -p -t "${p[$i]}" @agent "${targets[$i]}"
done
ensure_agent_ids "$tmp/empty-queue"
for i in "${!targets[@]}"; do
  aid="$(ensure_agent_id "${p[$i]}")"
  record_set "$aid" kind "${kinds[$i]}"
done

flags=("" "--any")
expected=(claude codex codex unknown)
for i in "${!targets[@]}"; do
  aid="$(pane_agent_id "${p[$i]}")"
  for j in "${!flags[@]}"; do
    mode="${expected[$i]}"
    body="$(request_body sender sample "${targets[$i]}" "${flags[$j]}" "$aid")"
    last_lines="$(printf '%s\n' "$body" | tail -n 2)"
    check "${targets[$i]} resolves as $mode" test "$(kind_for "$aid")" = "$mode"
    command="tmux-ask --from ${targets[$i]}${flags[$j]:+ ${flags[$j]}} --reply"
    check "${targets[$i]} reply options ${flags[$j]:-none}" contains "$body" "$command"
    case "$mode" in
      claude)
        expected_last_lines="$(printf 'MSG)\n[end of request from sender to claude]')"
        check 'Claude trailer ends exactly at the heredoc wrapper' test "$last_lines" = "$expected_last_lines"
        check 'Claude gets quoted heredoc reply form' contains "$body" "${command} <<'MSG'"
        check 'Claude trailer includes reply placeholder' contains "$body" '<your reply>'
        if contains "$body" '--message-file'; then fail 'Claude trailer does not switch to message-file'; fi
        ;;
      *)
        check 'quoted positional reply uses nameless delimiter' contains "$body" "$command -- \"answer\""
        check 'long reports use summary and inline body' contains "$body" '--reply --summary "short summary" -- "full report"'
        check 'reply preserves end marker' contains "$last_lines" "[end of request from sender to ${targets[$i]}]"
        if contains "$body" '--message-file' || contains "$body" "<<'MSG'"; then fail 'positional trailer stays portable'; fi
        ;;
    esac
  done
done

# Reply kind is formatting only; sending a reply requires no prior request.
body="$(reply_body sender 'answer' codex m123456789abc)"
check 'reply carries a delivery token' contains "$body" '[reply from sender to codex via tmux-ask · m123456789abc]'
check 'reply keeps matching end marker' contains "$body" '[end of reply from sender to codex]'
check 'request reply guidance omits retired ID' test "${body#*--request-id}" = "$body"
printf 'ok: receiver-aware reply formatting (%s checks)\n' "$count"
