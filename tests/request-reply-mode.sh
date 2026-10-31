#!/usr/bin/env bash
# Receiver-aware request instructions, with isolated tmux and request state.
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

flags=("" "--request-id r0123456789ab" "--any" "--any --request-id r0123456789ab")
expected=(claude codex codex unknown)
for i in "${!targets[@]}"; do
  aid="$(pane_agent_id "${p[$i]}")"
  for j in "${!flags[@]}"; do
    mode="${expected[$i]}"
    body="$(request_body sender sample "${targets[$i]}" "${flags[$j]}" "$aid")"
    check "${targets[$i]} resolves as $mode" test "$(kind_for "$aid")" = "$mode"
    command="tmux-ask --from ${targets[$i]}${flags[$j]:+ ${flags[$j]}} --reply sender"
    check "${targets[$i]} reply options ${flags[$j]:-none}" contains "$body" "$command"
    case "$mode" in
      claude)
        check 'Claude gets quoted heredoc reply form' contains "$body" "${command} <<'MSG'"
        check 'Claude trailer includes reply placeholder' contains "$body" '<your reply>'
        if contains "$body" '--message-file'; then fail 'Claude trailer does not switch to message-file'; fi
        ;;
      codex)
        check 'Codex gets quoted-argument option' contains "$body" 'a short reply'
        # shellcheck disable=SC2016
        check 'Codex gets unique message-file guidance' contains "$body" 'unique mktemp file under ${TMPDIR:-/tmp}/tmux-agents/<ME>/'
        if contains "$body" "<<'MSG'"; then fail 'Codex trailer avoids heredoc'; fi
        ;;
      *)
        check 'unknown executable gets quoted argv fallback' contains "$body" 'short reply as a quoted argument'
        if contains "$body" '--message-file' || contains "$body" "<<'MSG'"; then fail 'unknown trailer stays portable'; fi
        ;;
    esac
  done
done

# Exercise the real parser and ledger completion with the Claude heredoc form.
sender_id="$(pane_agent_id %0)"
claude_pane="${p[0]}"
claude_id="$(pane_agent_id "$claude_pane")"
set_peers %0 "$claude_pane"
set_peers "$claude_pane" %0
tmux copy-mode -t "$claude_pane"
TMUX_PANE=%0 "$B/tmux-ask" --from sender --any claude 'reply mode integration request' >/dev/null
queue="/tmp/tmux-agents-$(id -u)/queue/$(basename "${TMUX%%,*}")"
body_file=""
for f in "$queue"/*.msg; do
  [ -f "$f" ] || continue
  if grep -Fq 'reply mode integration request' "$f"; then body_file="$f"; break; fi
done
[ -n "$body_file" ] || fail 'real request body queued'
meta="${body_file%.msg}.meta"
rid="$(sed -n 's/^request_id=//p' "$meta")"
[ -n "$rid" ] || fail 'real request ID recorded'
grep -Fq -- "--any --request-id $rid" "$body_file" || fail 'real Claude trailer preserves any and request ID'

tmux send-keys -t "$claude_pane" -X cancel
TMUX_PANE="$claude_pane" "$B/tmux-ask" --from claude --any --reply --request-id "$rid" sender <<'MSG' >/dev/null
heredoc reply resolves this request
MSG
ledger="$(dirname "$(sessions_dir)")/requests/$rid.record"
grep -Fxq 'status=answered' "$ledger" || fail 'heredoc reply completes the matching request'
[ "$(pane_agent_id "$claude_pane")" = "$claude_id" ] || fail 'receiver identity remains stable'
[ "$(pane_agent_id %0)" = "$sender_id" ] || fail 'requester identity remains stable'

printf 'ok: receiver-aware reply instructions and request completion (%s checks)\n' "$count"
