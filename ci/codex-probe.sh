#!/usr/bin/env bash
# Probe Codex command forms against this checkout or an installed copy.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checkout_version="$(git -C "$repo_root" describe --tags --always --dirty 2>/dev/null || printf unknown)"
usage() {
  cat <<'EOF'
usage: ci/codex-probe.sh [--installed] [--binary PATH] [--profile NAME]... [--model MODEL] [--timeout SECONDS]
By default, tests this checkout's bin/. Use --installed to test commands on PATH.
Defaults to ~/.codex and configured codex-2nd. Requires authenticated Codex CLI,
tmux and Bash 3.2+. Codex may need network access.
Per-profile runtime is bounded (default 300s, maximum 900s). Not run in CI.
Uses a private tmux -L socket, fake peer and harmless stub child; cleans the
server, panes, its message queue and temp files. Never addresses the user's server.
The session uses `codex exec` (originator codex_exec); its tool surface may differ
from the interactive TUI used for agents launched by tmux-spawn.
EOF
}
die() { printf 'codex-probe: %s\n' "$*" >&2; exit 2; }
quote() { printf '%q' "$1"; }
codex_bin="$(command -v codex || true)"
model="" timeout_secs=300 profiles="" explicit=0 installed=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --installed) installed=1; shift ;;
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
command -v tmux >/dev/null 2>&1 || die 'tmux is required'
case "$codex_bin" in /*) ;; *) codex_bin="$(cd "$(dirname "$codex_bin")" && pwd)/$(basename "$codex_bin")" ;; esac
if [ "$installed" -eq 1 ]; then
  agents="$(command -v tmux-agents)"
  ask_cmd="$(command -v tmux-ask)"
  spawn_cmd="$(command -v tmux-spawn)"
  report_cmd="$(command -v tmux-agent-report)"
  tested_kind=installed
  selected_bin="$(dirname "$agents")"
else
  agents="$repo_root/bin/tmux-agents"
  ask_cmd="$repo_root/bin/tmux-ask"
  spawn_cmd="$repo_root/bin/tmux-spawn"
  report_cmd="$repo_root/bin/tmux-agent-report"
  [ -x "$agents" ] && [ -x "$ask_cmd" ] && [ -x "$spawn_cmd" ] && [ -x "$report_cmd" ] || die "checkout commands are missing under $repo_root/bin"
  tested_kind=checkout
  selected_bin="$repo_root/bin"
fi
original_path="$(printenv PATH)"
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
mkdir -p "$tmp/tools" "$tmp/agent-bin" "$tmp/state"
probe_path="$tmp/tools:$selected_bin:$original_path"
printf 'tmux-agents under test: %s (%s; checkout git describe: %s)\n' "$agents" "$tested_kind" "$checkout_version"
stub="$tmp/codex-stub"
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor arg do printf "%%s\\n" "$arg"; done >> %s\nprintf "CODEX-PROBE-STUB\\n"\nexec cat\n' "$(quote "$tmp/spawn.log")" > "$stub"
chmod +x "$stub"
ln -s "$stub" "$tmp/agent-bin/codex"
cat > "$tmp/tools/tmux-ask" <<WRAPPER
#!/bin/sh
exec $(quote "$ask_cmd") "\$@"
WRAPPER
cat > "$tmp/tools/tmux-spawn" <<WRAPPER
#!/bin/sh
exec $(quote "$spawn_cmd") "\$@"
WRAPPER
chmod +x "$tmp/tools/tmux-ask" "$tmp/tools/tmux-spawn"
printf 'probe ask file\n' > "$tmp/ask.msg"
printf 'probe spawn file\n' > "$tmp/spawn.msg"
wrapper="$tmp/tools/tmux-agent-report"
cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
set +e
$(quote "$report_cmd") "\$@"
status=\$?
activity="\$(tmux show-options -pqv -t "\${TMUX_PANE:-}" @activity 2>/dev/null)"
printf '%s\\t%s\\t%s\\n' "\$status" "\$*" "\$activity" >> $(quote "$tmp/report-effects.log")
exit "\$status"
WRAPPER
chmod +x "$wrapper"
export PATH="$probe_path"

model_status() {
  awk -F '|' -v c="$1" -v f="$2" '$1=="RESULT" && $2==c && $3==f { value=$4 } END { if (value) print value; else print "MISSING" }' "$3"
}

wait_for_marker() {
  local file="$1" marker="$2" limit=$((SECONDS + 10))
  while [ $SECONDS -lt "$limit" ]; do
    grep -Fq -- "$marker" "$file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

spawn_effect() {
  local pane="$1" marker="$2" pane_id
  pane_id="$(tmux -L "$socket" list-panes -a -F '#{pane_id}|#{@agent}' | awk -F '|' -v n="$pane" '$2==n { print $1; exit }')"
  [ -n "$pane_id" ] || return 1
  grep -Fq -- "$marker" "$tmp/spawn.log" 2>/dev/null
}

report_effect() {
  local expected="$1"
  awk -F '\t' -v e="$expected" '$1=="0" && index($2,e)>0 && $3==e { found=1 } END { exit !found }' "$tmp/report-effects.log" 2>/dev/null
}

check_row() {
  local command="$1" form="$2" model="$3" effect="$4" recommended="$5" outcome
  if [ "$model" = N/A ] && [ "$effect" = N/A ]; then
    outcome=N/A
  elif [ "$model" = OK ] && [ "$effect" = YES ]; then
    outcome=OK
  elif { [ "$model" = OK ] && [ "$effect" != YES ]; } || { [ "$model" = FAIL ] && [ "$effect" = YES ]; }; then
    outcome=MISMATCH
    printf 'MISMATCH: %s/%s model=%s side-effect=%s\n' "$command" "$form" "$model" "$effect" >&2
    failed=1
  else
    outcome=FAIL
  fi
  printf '%-20s %-20s %-8s %-12s %-10s\n' "$command" "$form" "$model" "$effect" "$outcome"
  if [ "$recommended" = 1 ] && [ "$outcome" != OK ]; then failed=1; fi
  [ "$model" != MISSING ] || failed=1
}

run_profile() {
  local p="$1" home name source peer prompt result events done_file launch sockpath start
  local ask_argv ask_heredoc ask_escalated ask_file spawn_argv spawn_heredoc spawn_escalated spawn_file
  home="$(profile_home "$p")" || die "profile is not configured: $p"
  [ -d "$home" ] || die "Codex home does not exist: $home"
  case "$p" in *[!a-zA-Z0-9_-]*) die "unsafe profile name: $p" ;; esac
  name="codex-probe-$p"; prompt="$tmp/$p.prompt"; result="$tmp/$p.result"
  events="$tmp/$p.events"; done_file="$tmp/$p.done"; launch="$tmp/$p.launch"
  ask_argv="probe-ask-argv-$p"; ask_heredoc="probe-ask-heredoc-$p"; ask_escalated="probe-ask-escalated-$p"; ask_file='probe ask file'
  spawn_argv="probe-spawn-argv-$p"; spawn_heredoc="probe-spawn-heredoc-$p"; spawn_escalated="probe-spawn-escalated-$p"; spawn_file='probe spawn file'
  : > "$tmp/peer.log"
  : > "$tmp/spawn.log"
  : > "$tmp/report-effects.log"
  printf '%s\n' "$ask_file" > "$tmp/ask.msg"
  printf '%s\n' "$spawn_file" > "$tmp/spawn.msg"
  cat > "$prompt" <<PROMPT
Private tmux Codex probe only. Do not inspect or modify other files, call external agents, or message outside this server. Run one command per tool call. Record actual outcomes; no retries except the explicitly escalated-heredoc rows. Do not chain or pipe tmux commands.
First emit SURFACE| followed by actual exposed shell tool names (direct shell or functions.exec/tools.exec_command).
Use these exact form keys: argv, heredoc, message-file, escalated-heredoc. After each test emit RESULT|COMMAND|FORM|OK|-. On failure use RESULT|COMMAND|FORM|FAIL|short error without pipes. Do not rename or qualify a form key. Plain argv, message-file where supported, and escalated-heredoc fallbacks are recommended and must pass. Unescalated heredocs are diagnostic only.
Sender is $name, receiver codex-probe-peer.
The parent independently checks the private receiver log, spawned panes and tasks, and activity options. Results are not accepted on self-report alone.
Record these exact tmux-ask rows after the matching commands: RESULT|tmux-ask|argv|..., RESULT|tmux-ask|heredoc|..., RESULT|tmux-ask|message-file|..., RESULT|tmux-ask|escalated-heredoc|...
tmux-ask argv: tmux-ask --from $name --any codex-probe-peer '$ask_argv'
tmux-ask heredoc diagnostic: tmux-ask --from $name --any codex-probe-peer <<'MSG'
$ask_heredoc
MSG
tmux-ask file: tmux-ask --from $name --any codex-probe-peer --message-file $(quote "$tmp/ask.msg") (contains $ask_file)
Repeat ask heredoc with narrow escalation for that command only.
Escalated tmux-ask command: tmux-ask --from $name --any codex-probe-peer '$ask_escalated'
Record these exact tmux-spawn rows after the matching commands: RESULT|tmux-spawn|argv|..., RESULT|tmux-spawn|heredoc|..., RESULT|tmux-spawn|message-file|..., RESULT|tmux-spawn|escalated-heredoc|...
tmux-spawn argv: tmux-spawn codex --from $name --name probe-argv --exact '$spawn_argv'
tmux-spawn heredoc diagnostic: tmux-spawn codex --from $name --name probe-heredoc --exact <<'MSG'
$spawn_heredoc
MSG
tmux-spawn file: tmux-spawn codex --from $name --name probe-file --exact --message-file $(quote "$tmp/spawn.msg") (contains $spawn_file)
Repeat spawn heredoc with narrow escalation for that command only.
Escalated tmux-spawn command: tmux-spawn codex --from $name --name probe-escalated --exact '$spawn_escalated'
tmux-agent-report has no message-file. Heredoc rows test shell/tool permission only; report text stays positional.
Record these exact tmux-agent-report rows after the matching commands: RESULT|tmux-agent-report|argv|..., RESULT|tmux-agent-report|heredoc|..., RESULT|tmux-agent-report|escalated-heredoc|..., RESULT|tmux-agent-report|message-file|N/A|unsupported.
tmux-agent-report argv: tmux-agent-report --from $name 'probe-report-argv-$p'
tmux-agent-report heredoc diagnostic: tmux-agent-report --from $name 'probe-report-heredoc-$p' <<'MSG'
unused report stdin
MSG
Repeat report heredoc with narrow escalation for that command only.
Escalated tmux-agent-report command: tmux-agent-report --from $name 'probe-report-escalated-$p'
For escalation through functions.exec, make one tools.exec_command call with sandbox_permissions=require_escalated and a short reason. End with SURFACE and every RESULT line, no Markdown table or code fence. Never claim success unless the tool returned success. Preserve diagnostic errors. Do not create files.
PROMPT
  cat > "$launch" <<LAUNCH
#!/usr/bin/env bash
set +e
export CODEX_HOME=$(quote "$home")
export TMUX_AGENTS_CODEX_HOMES=$(quote "$p=$home")
export XDG_STATE_HOME=$(quote "$tmp/state")
export PATH=$(quote "$probe_path")
unset TMUX_SPAWN_BIN
if [ -n $(quote "$model") ]; then
  $(quote "$agents") start $(quote "$p") --name $(quote "$name") --exact -- -c $(quote "shell_environment_policy.set.TMUX_SPAWN_BIN=\"$tmp/agent-bin\"") -c $(quote "shell_environment_policy.set.PATH=\"$probe_path\"") exec --ephemeral --skip-git-repo-check --json -o $(quote "$result") --model $(quote "$model") - < $(quote "$prompt") > $(quote "$events") 2>&1
else
  $(quote "$agents") start $(quote "$p") --name $(quote "$name") --exact -- -c $(quote "shell_environment_policy.set.TMUX_SPAWN_BIN=\"$tmp/agent-bin\"") -c $(quote "shell_environment_policy.set.PATH=\"$probe_path\"") exec --ephemeral --skip-git-repo-check --json -o $(quote "$result") - < $(quote "$prompt") > $(quote "$events") 2>&1
fi
status=\$?
printf '%s\\n' "\$status" > $(quote "$done_file")
exit 0
LAUNCH
  chmod +x "$launch"
  server=1
  tmux -L "$socket" -f /dev/null new-session -d -s probe -x 160 -y 50 -c "$tmp" /bin/sh || die 'cannot create private tmux server'
  tmux -L "$socket" has-session -t probe >/dev/null 2>&1 || die 'private server did not start'
  sockpath="$(tmux -L "$socket" display-message -p '#{socket_path}')"
  case "$sockpath" in */"$socket") ;; *) die "unsafe socket path: $sockpath" ;; esac
  queuedir="/tmp/tmux-agents-$(id -u)/queue/$socket"
  source="$(tmux -L "$socket" display-message -p '#{pane_id}')"
  peer_command="/bin/sh -c 'exec cat >> $(quote "$tmp/peer.log")'"
  peer="$(tmux -L "$socket" new-window -d -P -F '#{pane_id}' -n codex-probe-peer "$peer_command")"
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
  awk '/^SURFACE\|/ { print "Tool surface: " substr($0, 9) }' "$result"
  printf '%-20s %-20s %-8s %-12s %-10s\n' COMMAND FORM MODEL EFFECT RESULT
  local failed=0 expected model form recommended pane_name effect
  for form in argv heredoc message-file escalated-heredoc; do
    case "$form" in
      argv) expected="$ask_argv" ;;
      heredoc) expected="$ask_heredoc" ;;
      message-file) expected="$ask_file" ;;
      escalated-heredoc) expected="$ask_escalated" ;;
    esac
    model="$(model_status tmux-ask "$form" "$result")"
    effect=NO
    wait_for_marker "$tmp/peer.log" "$expected" && effect=YES || true
    recommended=0
    case "$form" in argv|message-file|escalated-heredoc) recommended=1 ;; esac
    check_row tmux-ask "$form" "$model" "$effect" "$recommended"
  done
  for form in argv heredoc message-file escalated-heredoc; do
    case "$form" in
      argv) expected="$spawn_argv"; pane_name=probe-argv ;;
      heredoc) expected="$spawn_heredoc"; pane_name=probe-heredoc ;;
      message-file) expected="$spawn_file"; pane_name=probe-file ;;
      escalated-heredoc) expected="$spawn_escalated"; pane_name=probe-escalated ;;
    esac
    model="$(model_status tmux-spawn "$form" "$result")"
    effect=NO
    if spawn_effect "$pane_name" "$expected"; then effect=YES; fi
    recommended=0
    case "$form" in argv|message-file|escalated-heredoc) recommended=1 ;; esac
    check_row tmux-spawn "$form" "$model" "$effect" "$recommended"
  done
  for form in argv heredoc escalated-heredoc; do
    case "$form" in
      argv) expected="probe-report-argv-$p" ;;
      heredoc) expected="probe-report-heredoc-$p" ;;
      escalated-heredoc) expected="probe-report-escalated-$p" ;;
    esac
    model="$(model_status tmux-agent-report "$form" "$result")"
    effect=NO
    report_effect "$expected" && effect=YES || true
    recommended=0
    case "$form" in argv|escalated-heredoc) recommended=1 ;; esac
    check_row tmux-agent-report "$form" "$model" "$effect" "$recommended"
  done
  model="$(model_status tmux-agent-report message-file "$result")"
  check_row tmux-agent-report message-file "$model" N/A 0
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

