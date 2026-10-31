#!/usr/bin/env bash
# Probe installed Codex command forms against a private tmux server.
set -euo pipefail
usage() {
  cat <<'EOF'
usage: ci/codex-probe.sh [--binary PATH] [--profile NAME]... [--model MODEL] [--timeout SECONDS]
Defaults to ~/.codex and configured codex-2nd. Requires authenticated Codex CLI,
tmux-agents commands on PATH, tmux and Bash 3.2+. Codex may need network access.
Per-profile runtime is bounded (default 300s, maximum 900s). Not run in CI.
Uses a private tmux -L socket, fake peer and harmless stub child; cleans the
server, panes, its message queue and temp files. Never addresses the user's server.
EOF
}
die() { printf 'codex-probe: %s\n' "$*" >&2; exit 2; }
quote() { printf '%q' "$1"; }
codex_bin="$(command -v codex || true)"
model="" timeout_secs=300 profiles="" explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --binary) [ "$#" -ge 2 ] || die '--binary needs a path'; codex_bin="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || die '--profile needs a name'; profiles="$profiles $2"; explicit=1; shift 2 ;;
    --model) [ "$#" -ge 2 ] || die '--model needs a value'; model="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die '--timeout needs seconds'; timeout_secs="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$timeout_secs" in ''|*[!0-9]*) die '--timeout must be an integer' ;; esac
[ "$timeout_secs" -ge 1 ] && [ "$timeout_secs" -le 900 ] || die '--timeout must be 1..900'
[ -n "$codex_bin" ] && [ -x "$codex_bin" ] || die 'Codex CLI missing; pass --binary PATH'
for c in tmux tmux-agents tmux-ask tmux-spawn tmux-agent-report; do command -v "$c" >/dev/null 2>&1 || die "missing installed command: $c"; done
case "$codex_bin" in /*) ;; *) codex_bin="$(cd "$(dirname "$codex_bin")" && pwd)/$(basename "$codex_bin")" ;; esac
homes="$(printenv TMUX_AGENTS_CODEX_HOMES 2>/dev/null || true)"
profile_home() {
  local wanted="$1" entry key
  if [ "$wanted" = codex ]; then printf '%s\n' "$HOME/.codex"; return 0; fi
  for entry in $homes; do
    key="$(printf '%s\n' "$entry" | cut -d= -f1)"
    [ "$key" = "$wanted" ] || continue
    printf '%s\n' "$entry" | cut -d= -f2-
    return 0
  done
  return 1
}
if [ "$explicit" -eq 0 ]; then
  [ ! -d "$HOME/.codex" ] || profiles="$profiles codex"
  [ -z "$(profile_home codex-2nd 2>/dev/null || true)" ] || profiles="$profiles codex-2nd"
  [ -n "$profiles" ] || die 'no default home; use --profile NAME'
fi
tmpbase="$(printenv TMPDIR 2>/dev/null || true)"; [ -n "$tmpbase" ] || tmpbase=/tmp
tmp="$(mktemp -d "$tmpbase/tmux-agents-codex-probe.XXXXXX")" || die 'cannot create temp directory'
socket="tmux-codex-probe-$$-$RANDOM-$RANDOM"
server=0 queuedir=""
# shellcheck disable=SC2329
cleanup() {
  if [ "$server" -eq 1 ]; then tmux -L "$socket" kill-server >/dev/null 2>&1 || true; fi
  case "$queuedir" in /tmp/tmux-agents-*/queue/tmux-codex-probe-*) rm -rf "$queuedir" ;; esac
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
unset TMUX TMUX_PANE
mkdir -p "$tmp/bin" "$tmp/state"
ln -s "$codex_bin" "$tmp/bin/codex"
stub="$tmp/probe-agent"
printf '#!/bin/sh\nprintf "PROBE-STUB %%s\\n" "$*"\nexec cat\n' > "$stub"
chmod +x "$stub"
ln -s "$stub" "$tmp/bin/probe-agent"
printf 'probe ask file\n' > "$tmp/ask.msg"
printf 'probe spawn file\n' > "$tmp/spawn.msg"
agents="$(command -v tmux-agents)"
run_profile() {
  local p="$1" home name source peer prompt result events done_file launch sockpath start
  home="$(profile_home "$p")" || die "profile is not configured: $p"
  [ -d "$home" ] || die "Codex home does not exist: $home"
  case "$p" in *[!a-zA-Z0-9_-]*) die "unsafe profile name: $p" ;; esac
  name="codex-probe-$p"; prompt="$tmp/$p.prompt"; result="$tmp/$p.result"
  events="$tmp/$p.events"; done_file="$tmp/$p.done"; launch="$tmp/$p.launch"
  cat > "$prompt" <<PROMPT
Private tmux Codex probe only. Do not inspect or modify other files, call external agents, or message outside this server. Run one command per tool call. Record actual outcomes; no retries except the explicitly escalated-heredoc rows. Do not chain or pipe tmux commands.
First emit SURFACE| followed by actual exposed shell tool names (direct shell or functions.exec/tools.exec_command).
Use these exact form keys: argv, heredoc, message-file, escalated-heredoc. After each test emit RESULT|COMMAND|FORM|OK|-. On failure use RESULT|COMMAND|FORM|FAIL|short error without pipes. Do not rename or qualify a form key. Plain argv, message-file where supported, and escalated-heredoc fallbacks are recommended and must pass. Unescalated heredocs are diagnostic only.
Sender is $name, receiver codex-probe-peer.
Record these exact tmux-ask rows after the matching commands: RESULT|tmux-ask|argv|..., RESULT|tmux-ask|heredoc|..., RESULT|tmux-ask|message-file|..., RESULT|tmux-ask|escalated-heredoc|...
tmux-ask argv: tmux-ask --from $name --any codex-probe-peer 'probe ask argv'
tmux-ask heredoc diagnostic: tmux-ask --from $name --any codex-probe-peer <<'MSG'
probe ask heredoc
MSG
tmux-ask file: tmux-ask --from $name --any codex-probe-peer --message-file $tmp/ask.msg
Repeat ask heredoc with narrow escalation for that command only.
Record these exact tmux-spawn rows after the matching commands: RESULT|tmux-spawn|argv|..., RESULT|tmux-spawn|heredoc|..., RESULT|tmux-spawn|message-file|..., RESULT|tmux-spawn|escalated-heredoc|...
tmux-spawn argv: tmux-spawn probe-agent --from $name --name probe-argv 'probe spawn argv'
tmux-spawn heredoc diagnostic: tmux-spawn probe-agent --from $name --name probe-heredoc <<'MSG'
probe spawn heredoc
MSG
tmux-spawn file: tmux-spawn probe-agent --from $name --name probe-file --message-file $tmp/spawn.msg
Repeat spawn heredoc with narrow escalation for that command only.
tmux-agent-report has no message-file. Heredoc rows test shell/tool permission only; report text stays positional.
Record these exact tmux-agent-report rows after the matching commands: RESULT|tmux-agent-report|argv|..., RESULT|tmux-agent-report|heredoc|..., RESULT|tmux-agent-report|escalated-heredoc|..., RESULT|tmux-agent-report|message-file|N/A|unsupported.
tmux-agent-report argv: tmux-agent-report --from $name 'probe report argv'
tmux-agent-report heredoc diagnostic: tmux-agent-report --from $name 'probe report heredoc' <<'MSG'
unused report stdin
MSG
Repeat report heredoc with narrow escalation for that command only.
For escalation through functions.exec, make one tools.exec_command call with sandbox_permissions=require_escalated and a short reason. End with SURFACE and every RESULT line, no Markdown table or code fence. Never claim success unless the tool returned success. Preserve diagnostic errors. Do not create files.
PROMPT
  cat > "$launch" <<LAUNCH
#!/usr/bin/env bash
set +e
export CODEX_HOME=$(quote "$home")
export TMUX_AGENTS_CODEX_HOMES=$(quote "$p=$home")
export TMUX_SPAWN_BIN=$(quote "$tmp/bin")
export XDG_STATE_HOME=$(quote "$tmp/state")
export PATH=$(quote "$tmp/bin:$PATH")
if [ -n $(quote "$model") ]; then
  $(quote "$agents") start $(quote "$p") --name $(quote "$name") --exact -- -c $(quote "shell_environment_policy.set.TMUX_SPAWN_BIN=\"$tmp/bin\"") exec --ephemeral --skip-git-repo-check --json -o $(quote "$result") --model $(quote "$model") - < $(quote "$prompt") > $(quote "$events") 2>&1
else
  $(quote "$agents") start $(quote "$p") --name $(quote "$name") --exact -- -c $(quote "shell_environment_policy.set.TMUX_SPAWN_BIN=\"$tmp/bin\"") exec --ephemeral --skip-git-repo-check --json -o $(quote "$result") - < $(quote "$prompt") > $(quote "$events") 2>&1
fi
status=\$?
printf '%s\\n' "\$status" > $(quote "$done_file")
exit 0
LAUNCH
  chmod +x "$launch"
  tmux -L "$socket" -f /dev/null new-session -d -s probe -x 160 -y 50 -c "$tmp" /bin/sh || die 'cannot create private tmux server'
  server=1
  tmux -L "$socket" has-session -t probe >/dev/null 2>&1 || die 'private server did not start'
  sockpath="$(tmux -L "$socket" display-message -p '#{socket_path}')"
  case "$sockpath" in */"$socket") ;; *) die "unsafe socket path: $sockpath" ;; esac
  queuedir="/tmp/tmux-agents-$(id -u)/queue/$socket"
  source="$(tmux -L "$socket" display-message -p '#{pane_id}')"
  peer="$(tmux -L "$socket" new-window -d -P -F '#{pane_id}' -n codex-probe-peer /bin/sh -c 'exec sleep 600')"
  tmux -L "$socket" set-option -p -t "$peer" @agent codex-probe-peer
  tmux -L "$socket" set-option -p -t "$peer" @tracked 1
  tmux -L "$socket" send-keys -t "$source" -l "$(quote /bin/bash) $(quote "$launch")"
  tmux -L "$socket" send-keys -t "$source" Enter
  start="$SECONDS"
  while [ ! -f "$done_file" ]; do
    if [ $((SECONDS - start)) -ge "$timeout_secs" ]; then printf 'TIMEOUT: %s after %ss\n' "$p" "$timeout_secs" >&2; return 1; fi
    sleep 1
  done
  status="$(cat "$done_file")"
  model_display="$model"; [ -n "$model_display" ] || model_display=configured-default
  printf '\n=== profile=%s model=%s binary=%s version=%s ===\n' "$p" "$model_display" "$codex_bin" "$("$codex_bin" --version 2>&1 | head -n 1)"
  if [ ! -s "$result" ]; then
    printf 'No final response (Codex exit %s); last event output:\n' "$status" >&2
    tail -n 30 "$events" >&2 || true
    return 1
  fi
  awk '/^SURFACE\|/ { print "Tool surface: " substr($0, 9) } /^RESULT\|/ { split($0, f, "|"); printf "%-20s %-20s %-6s %s\n", f[2], f[3], f[4], f[5] }' "$result"
  local failed=0 key cmd form
  for key in 'tmux-ask:argv' 'tmux-ask:message-file' 'tmux-ask:escalated-heredoc' 'tmux-spawn:argv' 'tmux-spawn:message-file' 'tmux-spawn:escalated-heredoc' 'tmux-agent-report:argv' 'tmux-agent-report:escalated-heredoc'; do
    cmd="$(printf '%s\n' "$key" | cut -d: -f1)"; form="$(printf '%s\n' "$key" | cut -d: -f2-)"
    if ! awk -F '|' -v c="$cmd" -v f="$form" '$1=="RESULT" && $2==c && $3==f && $4=="OK" { ok=1 } END { exit !ok }' "$result"; then
      printf 'FAILED recommended form or missing row: %s / %s\n' "$cmd" "$form" >&2; failed=1
    fi
  done
  for key in 'tmux-ask:heredoc' 'tmux-spawn:heredoc' 'tmux-agent-report:heredoc' 'tmux-agent-report:message-file'; do
    cmd="$(printf '%s\n' "$key" | cut -d: -f1)"; form="$(printf '%s\n' "$key" | cut -d: -f2-)"
    if ! awk -F '|' -v c="$cmd" -v f="$form" '$1=="RESULT" && $2==c && $3==f { found=1 } END { exit !found }' "$result"; then
      printf 'Missing diagnostic row: %s / %s\n' "$cmd" "$form" >&2; failed=1
    fi
  done
  [ "$status" = 0 ] || { printf 'Codex exec exited with status %s\n' "$status" >&2; failed=1; }
  grep -q '^SURFACE|' "$result" || { echo 'FAILED: missing tool surface'; failed=1; }
  return "$failed"
}
overall=0
for p in $profiles; do
  run_profile "$p" || overall=1
  if [ "$server" -eq 1 ]; then tmux -L "$socket" kill-server >/dev/null 2>&1 || true; server=0; fi
done
exit "$overall"

