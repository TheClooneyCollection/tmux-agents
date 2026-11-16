# Turn evidence and the one-slot unanswered-stop reminder. Sourced by lib.sh.
# Serialize delivery, sends and hooks per pane, separately from accounting.
turn_event() {
  local dir
  dir="$(sessions_dir)"; mkdir -p "$dir"
  perl -MFcntl=:flock -e '
    my ($lock, @cmd) = @ARGV;
    open(my $fh, ">>", $lock) or die "$!";
    flock($fh, LOCK_EX) or die "$!";
    system(@cmd); exit($? == -1 ? 1 : $? >> 8);
  ' "$dir/.turn-$1.lock" /bin/bash -c '. "$1"; shift; _turn_event "$@"' turn \
    "$(dirname "${BASH_SOURCE[0]}")/lib.sh" "$@"
}
turn_message_delivered() { turn_event "$1" delivered "$2" "$3" "${4:-}"; }
turn_message_sent() { turn_event "$1" sent "$2" "$3"; }
turn_begin() { turn_event "$1" start "${2:-message}" "${3:-prompt}"; }
turn_end() { turn_event "$1" end "${2:-}" "${3:-}"; }
turn_progress() { turn_event "$1" progress; }
turn_needs_you() { turn_event "$1" attention "$2"; }

_turn_get() { tmux show-options -pqv -t "$turn_pane" "@$1"; }
_turn_unset() { local key; for key in "$@"; do tmux set-option -pu -t "$turn_pane" "@$key"; done; }
_turn_begin() {
  local kind="$1" source="$2" state began
  state="$(_turn_get state)"; began="$(_turn_get turn_began)"
  _turn_unset owed_notified
  # Claude also runs prompt hooks for pasted notices. Only actual user input
  # ends an uninterrupted digest sequence; delivery and notice hooks keep it.
  if [ "$source" = prompt ] && [ "$kind" = local ]; then _turn_unset notes_digest_at; fi
  case "$source" in prompt|delivery) _turn_unset activity ;; esac
  if { [ "$source" = tool ] && [ -z "$began" ]; } ||
      { [ "$source" = prompt ] && [ "$state" != working ]; }; then
    tmux set-option -p -t "$turn_pane" @turn_began "$(date +%s)"
  fi
  if [ "$kind" = notice ]; then
    if [ -n "$(_turn_get perm_since)" ]; then
      agent_set_state "$turn_pane" needs_you
      return 0
    fi
    [ "$state" != needs_you ] || return 0
  fi
  # Tools resume hook questions, but do not clear explicit user attention.
  if [ "$source" = tool ] && [ "$state" = needs_you ]; then return 0; fi
  _turn_unset explicit_needs_you asking
  agent_set_wait "$turn_pane" perm ""
  agent_set_state "$turn_pane" working
}
_turn_event() {
  local turn_pane="$1" event="$2" sender kind token parent owed_to now matches requester state
  shift 2
  [ "$(_turn_get shell)" != 1 ] || return 0
  case "$event" in
    delivered)
      sender="$1" kind="$2" token="$3"
      parent="$(_turn_get parent)"; owed_to="$(_turn_get owed_to)"
      if [ -n "$parent" ] && [ -n "$sender" ]; then
        requester="$(find_pane_by_id "$sender")"
        if [ -n "$requester" ] && [ "$(tmux show-options -pqv -t "$requester" @shell)" != 1 ] &&
            { [ "$kind" = request ] || { [ "$kind" = reply ] && [ "$sender" = "$owed_to" ] && [ "$(_turn_get owed_asked)" = 1 ]; }; }; then
          tmux set-option -p -t "$turn_pane" @owed_to "$sender" \; \
            set-option -p -t "$turn_pane" @owed_msg "$token" \; \
            set-option -p -t "$turn_pane" @owed_at "$(date +%s)" \; \
            set-option -p -t "$turn_pane" @owed 1
          _turn_unset owed_settled owed_notified owed_asked
        fi
      fi
      if [ "$(_turn_get tracked)" = 1 ] && [ "$(pane_name_kind "$turn_pane")" = codex ]; then
        tmux set-option -p -t "$turn_pane" @last_delivered "$token"
        _turn_begin "$kind" delivery
      fi ;;
    sent)
      if [ "$1" = "$(_turn_get owed_to)" ]; then
        if [ "$2" = request ] && [ "$(_turn_get owed)" = 1 ]; then
          tmux set-option -p -t "$turn_pane" @owed_asked 1
        fi
        _turn_unset owed
      fi ;;
    start) _turn_begin "$1" "$2" ;;
    progress) _turn_begin message progress ;;
    attention)
      tmux set-option -p -t "$turn_pane" @explicit_needs_you 1 \; set-option -p -t "$turn_pane" @activity "$1"
      agent_set_state "$turn_pane" needs_you ;;
    end)
      matches=0
      if [ -n "$1" ]; then
        # Only complete header tokens count, never a substring or an empty ID.
        token="$(_turn_get last_delivered)"
        matches="$(printf '%s' "$1" | perl -MJSON::PP -e '
          local $/; my $j=eval {decode_json(<STDIN>)} || {};
          my ($latest,$owed,$rebound)=@ARGV; my $in=$j->{"input-messages"};
          if (ref($in) ne "ARRAY" || !length($latest)) { print length($latest) && $rebound eq "rebound" ? "stale" : "0"; exit }
          my %seen; for (@$in) { while (/\[(?:request|reply|notice) from \S+ to \S+ via tmux-ask \x{b7} (m[0-9a-f]{12})\]/g) { $seen{$1}=1 } }
          print !$seen{$latest} ? "stale" : length($owed) && $seen{$owed} ? "1" : "0";
        ' "$token" "$(_turn_get owed_msg)" "${2:-}")"
        if [ "$matches" = stale ]; then
          [ "${2:-}" = rebound ] || return 0
          _turn_unset last_delivered
        fi
      else
        now="$(_turn_get turn_began)"; token="$(_turn_get owed_at)"
        if [ -n "$now" ] && [ -n "$token" ] && [ "$token" -le "$now" ]; then matches=1; fi
      fi
      # A verified thread switch finishes this turn but carries no evidence
      # that an obligation spanning the old conversation was answered.
      [ "${2:-}" != rebound ] || matches=0
      _turn_unset turn_began
      [ "$matches" != 1 ] || tmux set-option -p -t "$turn_pane" @owed_settled 1
      state="$(_turn_get state)"
      if [ "$state" != needs_you ]; then
        state=idle; [ -z "$(_turn_get parent)" ] || state="done"
        agent_set_wait "$turn_pane" perm ""
      fi
      if [ "$state" = needs_you ] && [ -n "$(_turn_get perm_since)" ]; then
        agent_turn_state "$turn_pane" end-attention needs_you
      else
        agent_turn_state "$turn_pane" end "$state"
      fi
      tmux set-option -p -t "$turn_pane" @notes_idle_since "$(date +%s)"
      [ "${2:-}" != rebound ] || return 0
      if [ -n "$(_turn_get parent)" ] && [ "$(_turn_get owed)" = 1 ] &&
          [ "$(_turn_get owed_settled)" = 1 ] && [ "$(_turn_get owed_notified)" != 1 ]; then
        pane_has_working_descendant "$turn_pane" && return 0
        requester="$(find_pane_by_id "$(_turn_get owed_to)")"
        if [ -n "$requester" ] && [ "$(tmux show-options -pqv -t "$requester" @shell)" != 1 ]; then
          tmux set-option -p -t "$turn_pane" @owed_notified 1
          printf '%s\n' "$requester"
        fi
      fi ;;
  esac
}
