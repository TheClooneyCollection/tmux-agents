# Resume validation and ordered initial delivery for the chain launcher.
# Sourced by tmux-agents-start after lib.sh.

chain_resume_validate() {
  local kind="$1" id="$2" dir="$3" home key found
  if ! full_agent_kind "$kind"; then
    printf "warning: --main-resume is unsupported for '%s'; starting a fresh main\n" "$kind" >&2
    return 1
  fi
  if [[ ! $id =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    printf "warning: --main-resume ID '%s' is missing or malformed; starting a fresh main\n" "$id" >&2
    return 1
  fi
  if [ "$kind" = claude ]; then
    home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    key="$(printf '%s' "$dir" | LC_ALL=C sed 's/[^a-zA-Z0-9]/-/g')"
    found=""
    [ ! -f "$home/projects/$key/$id.jsonl" ] || found=1
  else
    home="${CODEX_HOME:-$HOME/.codex}"
    if [ "$kind" != codex ]; then home="$(codex_home_for "$kind")" || return 1; fi
    found="$(find "$home/sessions" -type f -name "rollout-*-$id.jsonl" -print -quit 2>/dev/null || true)"
  fi
  if [ -z "$found" ]; then
    printf "warning: --main-resume ID '%s' was not found for '%s' in its session store; starting a fresh main\n" "$id" "$kind" >&2
    return 1
  fi
}

# Check the cursor's input line, not old prompts in scrollback. A resumed
# transcript may contain arbitrary prompt-looking output. Never submit into
# a startup/trust dialog, a replacement pane, or tmux copy mode.
chain_claude_prompt() {
  local pane="$1" identity="$2" row screen line
  [ "$(pane_agent_id "$pane")" = "$identity" ] || return 1
  [ "$(tmux display -p -t "$pane" '#{pane_in_mode}')" != 1 ] || return 1
  row="$(tmux display -p -t "$pane" '#{cursor_y}')" || return 1
  screen="$(tmux capture-pane -p -t "$pane")" || return 1
  line="$(printf '%s\n' "$screen" | sed -n "$((row + 1))p")"
  [[ $line =~ ^[[:space:]]*❯[[:space:]]*$ ]] ||
    [[ $line =~ ^[[:space:]]*❯[[:space:]]+Try[[:space:]] ]]
}

# /rc on an already connected conversation opens its management dialog.
# Escape is the dialog's documented Continue action, not a permission choice.
chain_rc_dialog() {
  local screen
  [ "$(tmux display -p -t "$1" '#{pane_in_mode}')" != 1 ] || return 1
  screen="$(tmux capture-pane -p -t "$1")" || return 1
  [[ $screen = *'Remote Control'* && $screen = *'Disconnect this session'* &&
     $screen = *'❯ Continue'* && $screen = *'Enter to select · Esc to continue'* ]]
}

chain_wait_claude_prompt() {
  local pane="$1" identity="$2" allow_rc_dialog="${3:-0}" attempt
  for ((attempt=0; attempt<600; attempt++)); do
    [ "$(pane_agent_id "$pane")" = "$identity" ] || return 1
    if chain_claude_prompt "$pane" "$identity"; then return 0; fi
    if [ "$allow_rc_dialog" = 1 ] && chain_rc_dialog "$pane"; then
      tmux send-keys -t "$pane" Escape || return 1
      allow_rc_dialog=0
    fi
    sleep .1
  done
  printf 'warning: resumed Claude did not reach an empty prompt; chain prompt was not sent\n' >&2
  return 1
}

chain_resume_deliver() {
  local pane="$1" identity="$2" prompt="$3" delay buffer="tmux-chain-$$-${1#%}"
  # Match tmux-ask's configurable paste-to-Enter settling interval.
  settings_get delay TMUX_ASK_ENTER_DELAY @tmux_agents_ask_enter_delay 0.5
  chain_wait_claude_prompt "$pane" "$identity" || return 1
  tmux send-keys -t "$pane" -l /rc || return 1
  sleep "$delay"
  [ "$(pane_agent_id "$pane")" = "$identity" ] || return 1
  tmux send-keys -t "$pane" Enter || return 1
  sleep "$delay"
  chain_wait_claude_prompt "$pane" "$identity" 1 || return 1
  printf '%s' "$prompt" | tmux load-buffer -b "$buffer" - || return 1
  tmux paste-buffer -p -d -b "$buffer" -t "$pane" || return 1
  sleep "$delay"
  [ "$(pane_agent_id "$pane")" = "$identity" ] || return 1
  tmux send-keys -t "$pane" Enter
}
