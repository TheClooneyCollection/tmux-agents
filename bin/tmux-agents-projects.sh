# shellcheck disable=SC2154,SC2088
# here is assigned by the launcher; quoted tildes are literal config syntax.
# Shared project launcher settings, records and socket selection.
projects_settings() {
  settings_get projects_socket TMUX_MAIN_SEQUENCE_SOCKET @tmux_agents_main_sequence_socket ''
  if [ -n "$projects_socket" ]; then
    # Resolve settings on the requested socket, never the caller's server.
    # Called by the sourcing launchers.
    # shellcheck disable=SC2329
    tmux() { command tmux -L "$projects_socket" "$@"; }
    unset _TMUX_SETTINGS_LOADED
  fi
  settings_get projects_session TMUX_MAIN_SEQUENCE_SESSION @tmux_agents_main_sequence_session main
  settings_get projects_override TMUX_MAIN_SEQUENCE_CONFIG @tmux_agents_projects_config ''
  settings_get projects_agent TMUX_MAIN_SEQUENCE_AGENT @tmux_agents_main_sequence_agent ''
  settings_get projects_scan TMUX_CHAIN_SCAN_ROOT @tmux_agents_chain_scan_root ''
  projects_write="${projects_override:-${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agents/projects}"
  projects_read="$projects_write"
  if [ -z "$projects_override" ] && [ ! -e "$projects_read" ] && [ -f "$HOME/.config/tmux-main-sequence/projects" ]; then
    projects_read="$HOME/.config/tmux-main-sequence/projects"
  fi
}
projects_records() { "$here/tmux-agents-project-config" records "$projects_read" "$projects_write"; }
projects_canonical() {
  local path="$1"
  case "$path" in '~') path="$HOME" ;; '~/'*) path="$HOME/${path#\~/}" ;; esac
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)
}
projects_start_chain() {
  local dir="$1" target="$2" name="$3" resume="$4" socket_path socket_pane pane
  local args=(start chain "$dir") window_args=(-P -F '#{pane_id}')
  [ -z "$target" ] || args+=(--target "$target")
  [ -z "$name" ] || args+=(--name "$name")
  [ -z "$resume" ] || args+=(--main-resume "$resume")
  if [ -n "$projects_agent" ]; then
    if [ -n "$resume" ]; then printf 'warning: resume is unsupported for a custom main-sequence agent command; starting fresh\n' >&2; fi
    if [ -z "$target" ]; then target="$(tmux display -p '#{session_id}'):"; else window_args+=(-d); fi
    case "$target" in *:*) ;; *) target="$target:" ;; esac
    [ -n "$name" ] || name="${dir##*/}"
    pane="$(tmux new-window "${window_args[@]}" -t "$target" -n "${name:-root}" -c "$dir" "$projects_agent")" || return
    tmux set-option -w -t "$pane" automatic-rename off
    tmux set-option -w -t "$pane" allow-rename off
    printf '%s\n' "$pane"
  elif [ -n "$projects_socket" ]; then
    tmux has-session || return 1
    socket_path="$(tmux display -p '#{socket_path}')" || return 1
    case "$socket_path" in ''|*/default) die 'unsafe named project socket' ;; esac
    socket_pane="$(tmux display -p '#{pane_id}')" || return 1
    TMUX="$socket_path" TMUX_PANE="$socket_pane" FROM_PANE="$socket_pane" "$here/tmux-agents" "${args[@]}"
  else
    "$here/tmux-agents" "${args[@]}"
  fi
}
