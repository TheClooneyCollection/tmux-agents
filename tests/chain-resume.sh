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
prompt() {
  if [ -f "$TEST_LOG/ghost-prompt" ]; then
    printf '❯\302\240\033[2mresume the previous arbitrary request\033[22m\r\033[2C'
  else
    printf '❯ '
  fi
}
prompt
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$TEST_LOG/$TMUX_PANE.input"
  if [ "$line" = /rc ] && [ -f "$TEST_LOG/rc-dialog" ]; then
    printf 'Remote Control\nDisconnect this session\nEnter to select · Esc to continue\n❯ Continue'
    IFS= read -r -n 1 key
    [ "$key" = $'\033' ] || exit 9
    printf 'dismissed\n' > "$TEST_LOG/$TMUX_PANE.dialog"
    printf '\n'
  fi
  prompt
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
  launched_pane="$(cat "$tmp/out")"
  [[ $launched_pane =~ ^%[0-9]+$ ]]
  [ "$(wc -l < "$tmp/out" | tr -d ' ')" = 1 ]
  wait_file "$tmp/$launched_pane.args"
  tmux capture-pane -p -t "$launched_pane" | grep -q FAKE
}
# Input recognition also runs under C locale: UTF-8 and SGR are explicit.
(
  # shellcheck source=bin/lib.sh
  . "$B/lib.sh"
  pane_agent_id() { printf '%s\n' identity; }
  tmux() {
    case "$1" in
      display) printf '%s\n' "$prompt_position" ;;
      capture-pane) printf '%s\n' "$prompt_screen" ;;
      *) return 99 ;;
    esac
  }
  prompt_case() {
    local name="$1" want="$2" glyph="$3" expected="$4" actual=0
    prompt_position="$5"; prompt_screen="$6"
    LC_ALL=C chain_prompt_input %1 identity "$glyph" "$expected" || actual=$?
    if [ "$actual" != "$want" ]; then
      printf 'FAIL %s: expected=%s actual=%s position=%s screen=%q\n' \
        "$name" "$want" "$actual" "$prompt_position" "$prompt_screen" >&2
      exit 1
    fi
  }
  prompt_case empty 0 ❯ '' 0:0:2 '❯'
  prompt_case placeholder 0 ❯ '' 0:0:2 $'❯ \033[2mTry a request\033[0m'
  prompt_case history 0 ❯ '' 0:0:2 $'❯\302\240\033[2mearlier request\033[22m'
  prompt_case draft 1 ❯ '' 0:0:2 '❯ Try a request'
  prompt_case cursor-in-ghost 1 ❯ '' 0:0:3 $'❯ \033[2mhistory'
  prompt_case reset-draft 1 ❯ '' 0:0:2 $'❯ \033[2mghost\033[22mdraft'
  prompt_case reset-all 1 ❯ '' 0:0:2 $'❯ \033[2mghost\033[0mdraft'
  prompt_case color-not-dim 1 ❯ '' 0:0:2 $'❯ \033[38;2;2;22;0mdraft'
  prompt_case indexed-not-dim 1 ❯ '' 0:0:2 $'❯ \033[38;5;2mdraft'
  prompt_case combined-color 0 ❯ '' 0:0:2 $'❯ \033[1;2;38;2;22;0;2mhistory'
  prompt_case colon-color 0 ❯ '' 0:0:2 $'❯ \033[2;38:2::22:0:2mhistory'
  prompt_case codex 0 › '' 0:0:2 $'› \033[2mhistory'
  prompt_case codex-background 0 › '' 0:0:2 $'\033[1m›\033[0m \033[48;2;72;76;92m \033[2mAsk Codex to do anything\033[0m \033[48;2;72;76;92m'
  prompt_case codex-draft 1 › '' 0:0:2 $'\033[1m›\033[0m \033[48;2;72;76;92mdraft'
  prompt_case codex-command-padding 0 › /new 0:0:6 $'\033[1m›\033[0m /new\033[48;2;72;76;92m '
  prompt_case blank-draft-cursor 1 › '' 0:0:3 '›  '
  prompt_case exact-command 0 ❯ /clear 0:0:8 $'❯ /clear\033[2mhistory'
  prompt_case extra-input 1 ❯ /clear 0:0:8 '❯ /clear more'
  prompt_case command-cursor 1 ❯ /clear 0:0:7 '❯ /clear'
  prompt_case dim-command 1 ❯ /clear 0:0:8 $'❯ \033[2m/clear'
  prompt_case copy-mode 1 ❯ '' 1:0:2 '❯'
  prompt_case cursor-row 1 ❯ '' 0:1:2 $'❯\nstartup dialog'
  if chain_prompt_input %1 replacement ❯; then
    echo 'FAIL replacement identity accepted' >&2; exit 1
  fi
)
echo 'PASS prompt input guards dim spans, extended colors, identity, cursor and exact commands'
launch --main-resume "$claude_id" --main claude --worker extra
if [ -s "$tmp/err" ]; then cat "$tmp/err" >&2; exit 1; fi
python3 - "$tmp/$launched_pane.args" "$claude_id" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[-2:]==[b'--resume',sys.argv[2].encode()],args
assert len(args)==4 and args[0]==b'--settings',args
PY
[ ! -e "$tmp/$launched_pane.input" ]
: > "$tmp/$launched_pane.release"
wait_file "$tmp/$launched_pane.input"
for ((i=0;i<200;i++)); do
  if grep -q 'The current agent remains main.' "$tmp/$launched_pane.input"; then break; fi
  sleep .05
done
python3 - "$tmp/$launched_pane.input" <<'PY'
import sys
s=open(sys.argv[1]).read()
assert s.startswith('/rc\nstart the chain.'),repr(s)
assert 'worker\textra\texplicit' in s,s
assert s.count('/rc')==1,s
PY
[[ $(tmux display -p -t "$launched_pane" '#{@agent}') = claude-* ]]
echo 'PASS Claude resumes without prompt argv, waits for readiness, submits /rc before chain prompt'
# An already-active Remote Control session opens its own Continue dialog.
: > "$tmp/rc-dialog"
launch --main-resume "$claude_id" --main claude
: > "$tmp/$launched_pane.release"
wait_file "$tmp/$launched_pane.dialog"
for ((i=0;i<200;i++)); do
  if [ -f "$tmp/$launched_pane.input" ] && grep -q 'The current agent remains main.' "$tmp/$launched_pane.input"; then break; fi
  sleep .05
done
python3 - "$tmp/$launched_pane.input" <<'PYTEST'
import sys
s=open(sys.argv[1]).read()
assert s.startswith('/rc\nstart the chain.'),repr(s)
assert 'The current agent remains main.' in s,s
PYTEST
rm "$tmp/rc-dialog"
echo 'PASS already-active Remote Control dialog continues before the chain prompt'
# A dim history suggestion is empty input, including the NBSP separator.
: > "$tmp/ghost-prompt"
launch --main-resume "$claude_id" --main claude
: > "$tmp/$launched_pane.release"
wait_file "$tmp/$launched_pane.input"
for ((i=0;i<200;i++)); do
  if grep -q 'The current agent remains main.' "$tmp/$launched_pane.input"; then break; fi
  sleep .05
done
python3 - "$tmp/$launched_pane.input" <<'PYGHOST'
import sys
s=open(sys.argv[1]).read()
assert s.startswith('/rc\nstart the chain.'),repr(s)
assert 'The current agent remains main.' in s,s
PYGHOST
rm "$tmp/ghost-prompt"
echo 'PASS dim history ghost with NBSP accepts /rc and chain prompt'

for main in codex extra; do
  id="$codex_id"; [ "$main" != extra ] || id="$profile_id"
  launch --main "$main" --main-resume "$id"
  if [ -s "$tmp/err" ]; then cat "$tmp/err" >&2; exit 1; fi
  python3 - "$tmp/$launched_pane.args" "$id" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert args[0]==b'resume',args
assert args[-2]==sys.argv[2].encode(),args
assert args[-1].startswith(b'start the chain.'),args
assert b'/rc' not in args,args
PY
  [ ! -e "$tmp/$launched_pane.input" ]
  if [ "$main" = extra ]; then [ "$(cat "$tmp/$launched_pane.home")" = "$tmp/profile" ]; fi
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
  python3 - "$tmp/$launched_pane.args" "$invalid" <<'PY'
import sys
args=open(sys.argv[1],'rb').read().split(b'\0')[:-1]
assert b'--resume' not in args and b'resume' not in args,args
if sys.argv[2]=='unsupported': assert args==[b''],args
else: assert args[-1].startswith(b'start the chain.'),args
PY
  [ ! -e "$tmp/$launched_pane.input" ]
  echo "PASS $invalid ID falls back with warning and pane-only stdout"
done
"$B/tmux-agents" start --help | grep -q -- '--main-resume ID'
echo 'PASS help describes --main-resume'
