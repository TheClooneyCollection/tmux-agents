#!/usr/bin/env bash
# Chain main conversation resume, ordered Claude /rc, profiles and fresh fallback.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-agents-chain-resume-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-chain-resume.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/profile/sessions/2026/11/14" "$tmp/codex/sessions"
for kind in claude codex other; do
  cat > "$tmp/bin/$kind" <<'STUB'
#!/usr/bin/env bash
printf 'FAKE %s\n' "${0##*/}"
printf '%s\0' "$@" > "$TEST_LOG/$TMUX_PANE.args"
printf '%s\n' "${CODEX_HOME:-}" > "$TEST_LOG/$TMUX_PANE.home"
# Explicit release gate proves no /rc is sent before the input is ready.
if [ "${0##*/}" = claude ] && [[ " $* " = *' --resume '* ]]; then
  printf 'startup dialog\n'
  while [ ! -f "$TEST_LOG/$TMUX_PANE.release" ]; do sleep .05; done
fi
printf '❯ '
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$TEST_LOG/$TMUX_PANE.input"
  printf '❯ '
done
STUB
  chmod +x "$tmp/bin/$kind"
done
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED TMUX_AGENTS_DEPTH
unset TMUX_AGENTS_CHAIN_MAIN TMUX_AGENTS_CHAIN_SECONDARY TMUX_AGENTS_CHAIN_WORKER
export XDG_STATE_HOME="$tmp/state" TEST_LOG="$tmp" TMUX_SPAWN_BIN="$tmp/bin"
export CLAUDE_CONFIG_DIR="$tmp/claude" CODEX_HOME="$tmp/codex" TMUX_AGENTS_CODEX_HOMES="extra=$tmp/profile"
export PATH="$tmp/bin:$PATH"
claude_id=11111111-1111-4111-8111-111111111111
codex_id=22222222-2222-4222-8222-222222222222
profile_id=33333333-3333-4333-8333-333333333333
key="$(printf '%s' "$tmp/project" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$key"
printf '{}\n' > "$CLAUDE_CONFIG_DIR/projects/$key/$claude_id.jsonl"
printf '{}\n' > "$CODEX_HOME/sessions/rollout-2026-11-14-$codex_id.jsonl"
printf '{}\n' > "$tmp/profile/sessions/2026/11/14/rollout-2026-11-14-$profile_id.jsonl"
tmux -L "$sock" -f /dev/null new-session -d -s work -x 180 -y 50 cat
tmux -L "$sock" has-session || exit 1
socket="$(tmux -L "$sock" display -p '#{socket_path}')"
case "$socket" in ''|*/default) echo 'unsafe socket' >&2; exit 1 ;; esac
export TMUX="$socket,1,0"
. "$here/tests/helpers/cleanup.sh"
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
tmux set -g default-shell /bin/sh
wait_file() { local i; for ((i=0;i<200;i++)); do [ ! -s "$1" ] || return 0; sleep .05; done; return 1; }
launch() {
  "$B/tmux-agents" start chain --target work "$tmp/project" "$@" > "$tmp/out" 2> "$tmp/err"
  pane="$(cat "$tmp/out")"
  [[ $pane =~ ^%[0-9]+$ ]]
  [ "$(wc -l < "$tmp/out" | tr -d ' ')" = 1 ]
  wait_file "$tmp/$pane.args"
  tmux capture-pane -p -t "$pane" | grep -q FAKE
}
launch --main-resume "$claude_id" --main claude --worker extra
if [ -s "$tmp/err" ]; then cat "$tmp/err" >&2; exit 1; fi
python3 - "$tmp/$pane.args" "$claude_id" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[-2:]==[b'--resume',sys.argv[2].encode()],args
assert len(args)==4 and args[0]==b'--settings',args
PY
[ ! -e "$tmp/$pane.input" ]
: > "$tmp/$pane.release"
wait_file "$tmp/$pane.input"
for ((i=0;i<200;i++)); do
  if grep -q 'The current agent remains main.' "$tmp/$pane.input"; then break; fi
  sleep .05
done
python3 - "$tmp/$pane.input" <<'PY'
import sys
s=open(sys.argv[1]).read()
assert s.startswith('/rc\nstart the chain.'),repr(s)
assert 'worker\textra\texplicit' in s,s
assert s.count('/rc')==1,s
PY
[[ $(tmux display -p -t "$pane" '#{@agent}') = claude-* ]]
echo 'PASS Claude resumes without prompt argv, waits for readiness, submits /rc before chain prompt'
for main in codex extra; do
  id="$codex_id"; [ "$main" != extra ] || id="$profile_id"
  launch --main "$main" --main-resume "$id"
  if [ -s "$tmp/err" ]; then cat "$tmp/err" >&2; exit 1; fi
  python3 - "$tmp/$pane.args" "$id" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[0]==b'resume',args
assert args[-2]==sys.argv[2].encode(),args
assert args[-1].startswith(b'start the chain.'),args
assert b'/rc' not in args,args
PY
  [ ! -e "$tmp/$pane.input" ]
  if [ "$main" = extra ]; then [ "$(cat "$tmp/$pane.home")" = "$tmp/profile" ]; fi
  echo "PASS $main resume argv, selected home and no /rc"
done
for invalid in missing malformed unknown wrong-kind wrong-profile unsupported empty; do
  case "$invalid" in
    missing) launch --main-resume --main claude ;;
    empty) launch --main-resume '' --main claude ;;
    malformed) launch --main-resume '../bad' ;;
    unknown) launch --main-resume aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa ;;
    wrong-kind) launch --main-resume "$codex_id" --main claude ;;
    wrong-profile) launch --main-resume "$codex_id" --main extra ;;
    unsupported) launch --main-resume "$claude_id" --main other ;;
  esac
  grep -q 'warning: --main-resume.*starting a fresh main' "$tmp/err"
  python3 - "$tmp/$pane.args" "$invalid" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert b'--resume' not in args and b'resume' not in args,args
if sys.argv[2]=='unsupported': assert args==[b''],args
else: assert args[-1].startswith(b'start the chain.'),args
PY
  [ ! -e "$tmp/$pane.input" ]
  echo "PASS $invalid ID falls back with warning and pane-only stdout"
done
"$B/tmux-agents" start --help | grep -q -- '--main-resume ID'
echo 'PASS help describes --main-resume'
