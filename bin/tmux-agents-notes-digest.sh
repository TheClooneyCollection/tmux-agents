#!/usr/bin/env bash
# Independent, identity-scoped observer. Never depends on the status chip.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
. "$here/notes-lib.sh"
mode="${1:-}" identity="${2:-}"
valid_agent_id "$identity" || exit 1
case "$mode" in --start|--watch|--watch-locked|--once) ;; *) exit 1 ;; esac
settings_get notes_digest_secs TMUX_AGENTS_NOTES_DIGEST_SECS @tmux_agents_notes_digest_secs 300
# settings_get assigns this variable by name.
# shellcheck disable=SC2154
case "$notes_digest_secs" in ''|*[!0-9]*|0) exit 0 ;; esac
notes_digest_secs=$((10#$notes_digest_secs))
[ "$notes_digest_secs" -gt 0 ] || exit 0

# Return 10 when there is nothing left to observe, 0 for a live receiver.
check_digest() {
  local pane snapshot count state dead tracked shell permission asking explicit idle at sent now summary watermark
  pane="$(find_pane_by_id "$identity")"
  [ -n "$pane" ] || return 10
  snapshot="$(tmux display-message -p -t "$pane" '#{pane_dead}|#{@tracked}|#{@shell}|#{@state}|#{@perm_since}|#{@asking}|#{@explicit_needs_you}|#{@notes_idle_since}|#{@notes_digest_at}|#{@notes_digest_sent_at}')" || return 10
  IFS='|' read -r dead tracked shell state permission asking explicit idle at sent <<< "$snapshot"
  [ "$dead" != 1 ] && [ "$shell" != 1 ] && [ "$tracked" = 1 ] || return 10
  snapshot="$(notes_snapshot "$identity")"
  count="$(printf '%s' "$snapshot" | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{count}')"
  [ "$count" -gt 0 ] || return 10
  case "$state" in idle|done) ;; *) return 0 ;; esac
  [ -z "$permission$asking$explicit" ] || return 0
  user_busy "$pane" && return 0
  now="$(date +%s)"
  [ -n "$idle" ] || idle="$(tmux show-option -pqv -t "$pane" @state_since)"
  case "$idle" in ''|*[!0-9]*) idle="$now"; tmux set-option -p -t "$pane" @notes_idle_since "$idle" ;; esac
  case "$sent" in ''|*[!0-9]*) ;; *) [ "$sent" -le "$idle" ] || idle="$sent" ;; esac
  [ "$((now - idle))" -ge "$notes_digest_secs" ] || return 0
  snapshot="$(notes_snapshot "$identity")"
  count="$(printf '%s' "$snapshot" | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{count}')"
  [ "$count" -gt 0 ] || return 10
  watermark="$(printf '%s' "$snapshot" | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{latest_id}')"
  summary="$(printf '%s' "$snapshot" | perl -MJSON::PP -MEncode=decode -e '
    local $/; my $s=decode_json(<STDIN>); my ($since,$name)=@ARGV;
    my @time=localtime($since); binmode STDOUT, ":encoding(UTF-8)";
    printf "%s agent notes since %02d:%02d: %s. Read with: tmux-notes --from %s --all --keep-unread",
      $s->{count}, $time[2], $time[1],
      join("; ", map {"$_->{name} ($_->{count}): $_->{latest}"} @{$s->{senders}}), decode("UTF-8",$name);
  ' "${at:-$idle}" "$(pane_name "$pane")")"
  [ -z "$at" ] || summary="Continuing from last update ... $summary"
  # The internal sender rechecks readiness under delivery and turn locks. It
  # never queues a digest, and stamps the exact observed batch on success.
  "$here/tmux-ask" --notes-digest "$pane" "$identity" "$summary" "$watermark" >/dev/null 2>&1 || true
}

case "$mode" in
  --start)
    [ -d "$(notes_dir)/$identity" ] || exit 0
    count="$(notes_snapshot "$identity" | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{count}')"
    [ "$count" -gt 0 ] || exit 0
    [ -n "$(find_pane_by_id "$identity")" ] || exit 0
    # A detached child must not inherit tmux-ask's identity/receiver locks or
    # caller pipes. The receiver lock below elects exactly one observer.
    perl -MPOSIX=setsid -e '
      my $pid=fork(); defined($pid) or die "fork: $!"; exit 0 if $pid;
      setsid(); open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null";
      for (3..255) {POSIX::close($_)}
      delete $ENV{TMUX_ASK_IDENTITY_LOCKED};
      exec "/bin/bash", @ARGV; exit 1;
    ' "$here/tmux-agents-notes-digest.sh" --watch "$identity"
    ;;
  --watch)
    with_lock "$(notes_dir)/.digest-$identity.lock" /bin/bash "$here/tmux-agents-notes-digest.sh" --watch-locked "$identity"
    ;;
  --once)
    result=0; check_digest || result=$?
    [ "$result" = 0 ] || [ "$result" = 10 ]
    ;;
  --watch-locked)
    trap 'exit 0' TERM INT HUP
    step=30; [ "$notes_digest_secs" -ge 30 ] || step="$notes_digest_secs"
    while :; do
      result=0; check_digest || result=$?
      [ "$result" != 10 ] || exit 0
      sleep "$step"
    done
    ;;
esac
