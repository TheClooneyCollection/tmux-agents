# Shared helpers for the tmux-* agent pairing scripts. Sourced, not executed.
#
# State lives on the panes themselves as tmux user options:
#   @agent  this pane's name (unique across the tmux server)
#   @peers  space-separated pane ids this pane is connected to
# Pane ids (%12) survive pane moves, and the options vanish with the pane.

die() {
  printf '%s: %s\n' "$(basename "$0")" "$*" >&2
  exit 1
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux not found"
  if ! tmux list-sessions >/dev/null 2>&1; then
    [ -n "${TMUX:-}" ] && die "can't reach the tmux server. In Codex this means the command ran in the sandbox: run tmux-* commands on their own (not chained with other commands) so the allow rule applies, or ask for escalated permissions."
    die "no tmux server running"
  fi
}

# display-message -t exits 0 with empty output for a closed pane id, so check the list.
pane_alive() {
  local panes
  panes="$(tmux list-panes -a -F '#{pane_id}')"
  printf '%s\n' "$panes" | grep -qx -- "$1"
}

pane_name() {
  tmux display-message -p -t "$1" '#{@agent}' 2>/dev/null
}

pane_command() {
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

pane_location() {
  tmux display-message -p -t "$1" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
}

# Print the id of the pane named $1, if any.
find_pane() {
  tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$1" '$2 == n { print $1; exit }'
}

# The pane this script acts for: --from (a name or pane id), else $TMUX_PANE.
# Codex runs commands in a shared app-server daemon whose TMUX_PANE is the
# pane it started in, so agents pass --from with their own name.
self_pane() {
  local pane="${FROM_PANE:-${TMUX_PANE:-}}" mine
  [ -n "$pane" ] || die "not inside a tmux pane (pass --from <your name>)"
  case "$pane" in
    %*) ;;
    *)
      pane="$(find_pane "$FROM_PANE")"
      if [ -z "$pane" ]; then
        # An unknown --from from a freshly opened, unnamed agent: name its
        # own pane, as long as $TMUX_PANE can be trusted to be that pane.
        mine="${TMUX_PANE:-}"
        if trusted_pane && [ -n "$mine" ] && pane_alive "$mine" && [ -z "$(pane_name "$mine")" ]; then
          auto_name "$mine" >/dev/null || die "couldn't give pane $mine a name"
          pane="$mine"
        elif trusted_pane && [ -n "$mine" ] && [ -n "$(pane_name "$mine")" ]; then
          die "no agent named '$FROM_PANE'; you are $(pane_name "$mine") (pass --from $(pane_name "$mine"))"
        else
          die "no agent named '$FROM_PANE'"
        fi
      fi
      ;;
  esac
  pane_alive "$pane" || die "pane $pane no longer exists"
  printf '%s\n' "$pane"
}

# $TMUX_PANE is this agent's own pane: Claude runs commands in its own
# process, and pinned Codex (tmux-spawn or the fish wrappers) has it set
# per session. Unpinned Codex may see another pane's.
trusted_pane() {
  [ -n "${CLAUDECODE:-}" ] || [ -n "${TMUX_AGENTS_PINNED:-}" ]
}

# Give unnamed pane $1 a generated name (<command>-<dir>-<N>) and print it.
# Unless $2 is "quiet", tell the caller on stderr that this is now its name.
auto_name() {
  local n try
  # Runs inside $(...), where set -e doesn't apply: check every step. Two
  # agents naming themselves at once can pick the same name, so confirm it
  # is ours alone after writing, and move on to the next number if not.
  for try in 1 2 3; do
    n="$(suggest_name "$1")" || return 1
    set_name "$1" "$n" || return 1
    [ "$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk -v n="$n" '$2 == n && !seen[$1]++' | wc -l | tr -d ' ')" -gt 1 ] || break
    tmux set-option -pu -t "$1" @agent 2>/dev/null || true
    [ "$try" -lt 3 ] || return 1
    sleep "0.$((RANDOM % 5))$((RANDOM % 10))"
  done
  refresh_labels
  [ "${2:-}" = quiet ] || printf '%s: this pane had no name, so it is now "%s"; pass --from %s from now on\n' "$(basename "$0")" "$n" "$n" >&2
  printf '%s\n' "$n"
}

valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._~-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Replace characters names can't hold (spaces, slashes, ...) with '-'.
sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._~-' '-'
}

# Suggest "<command>-<dir>-<N>" for pane $1: dir is the cwd basename (~ for
# home), N is one past the highest number already used with that prefix.
# Shells are left out of the prefix, since the agent hasn't started yet.
# Extra args count as taken names (suggestions not yet applied).
suggest_name() {
  local pane="$1"; shift
  name_for "$(pane_command "$pane")" "$(tmux display-message -p -t "$pane" '#{pane_current_path}')" "$@"
}

# Name for command $1 running in directory $2; extra args count as taken.
name_for() {
  local cmd="$1" dir="$2" base max
  shift 2
  if [ "$dir" = "$HOME" ]; then
    dir="~"
  else
    dir="$(sanitize_name "$(basename "$dir")")"
  fi
  case "$cmd" in
    bash|zsh|fish|sh|dash|ksh|tcsh|nu|'') base="$dir" ;;
    *) base="$(sanitize_name "$cmd")-$dir" ;;
  esac
  max="$( { tmux list-panes -a -F '#{@agent}'; [ $# -eq 0 ] || printf '%s\n' "$@"; } | awk -v b="$base-" '
    index($0, b) == 1 { n = substr($0, length(b) + 1); if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0 }
    END { print m + 0 }')"
  printf '%s-%d\n' "$base" "$((max + 1))"
}

# $1, or $1-2, $1-3... whichever no pane holds yet.
unique_name() {
  local base="$1" name="$1" n=1
  while [ -n "$(find_pane "$name")" ]; do
    n=$((n + 1))
    name="$base-$n"
  done
  printf '%s\n' "$name"
}

# Hidden sub agents live in one session per project: agents-<project>.
# The project is the git root's basename, else the directory's; tmux
# session names can't hold '.' or ':'.
agents_session_for() {
  settings_get AGENTS_PREFIX TMUX_AGENTS_PREFIX @tmux_agents_session_prefix agents
  local dir="$1" root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || root="$dir"
  if [ "$root" = "$HOME" ]; then
    printf '%s-home\n' "$AGENTS_PREFIX"
  else
    printf '%s-%s\n' "$AGENTS_PREFIX" "$(printf '%s' "$(basename "$root")" | tr -c 'A-Za-z0-9_-' '-')"
  fi
}

# The project pane $1 belongs to, as in agents-<project>: a hidden sub
# agent's from its session, any other pane's from its directory.
pane_project() {
  settings_get AGENTS_PREFIX TMUX_AGENTS_PREFIX @tmux_agents_session_prefix agents
  local session p
  session="$(tmux display-message -p -t "$1" '#{session_name}')"
  if is_agents_session "$session"; then p="$session"
  else p="$(agents_session_for "$(tmux display-message -p -t "$1" '#{pane_current_path}')")"
  fi
  printf '%s\n' "${p#"$AGENTS_PREFIX"-}"
}

is_agents_session() {
  settings_get AGENTS_PREFIX TMUX_AGENTS_PREFIX @tmux_agents_session_prefix agents
  case "$1" in "$AGENTS_PREFIX"-*) return 0 ;; *) return 1 ;; esac
}

# Succeeds if the user seems busy in pane $1: it is in copy mode (they're
# scrolling it, and Enter would go to copy mode), or a client is showing it
# and had a keypress in the last TMUX_ASK_IDLE_SECS (default 8).
user_busy() {
  [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}')" != 1 ] || return 0
  user_typing "$1"
}

# Succeeds if a client showing pane $1 had a keypress (or scroll) in the
# last TMUX_ASK_IDLE_SECS (default 8).
user_typing() {
  local idle_secs
  settings_get idle_secs TMUX_ASK_IDLE_SECS @tmux_agents_ask_idle_secs 8
  tmux list-clients -F '#{pane_id} #{client_activity}' | awk -v p="$1" -v now="$(date +%s)" \
    -v w="$idle_secs" '$1 == p && now - $2 < w { f = 1 } END { exit !f }'
}

# Message bodies for tmux-ask. Requests carry their own reply instructions,
# so a receiver that never loaded the skill can still answer.
# Args: sender, message, receiver[, extra reply flags]. The receiver's name
# goes into the reply command as --from, so it works even where TMUX_PANE
# is wrong; $4 adds flags such as --any when the two aren't connected.
# Both end with an [end of ...] line: text outside the markers in the same
# prompt was typed by the user (a draft can get submitted along with it).
request_body() {
  printf '[request from %s to %s via tmux-ask]\n%s\n\n(You are %s. When done, send your answer back with: tmux-ask --from %s%s --reply %s <<'"'"'MSG'"'"'\n<your reply>\nMSG)\n[end of request from %s to %s]' "$1" "$3" "$2" "$3" "$3" "${4:+ $4}" "$1" "$1" "$3"
}

reply_body() {
  printf '[reply from %s to %s via tmux-ask]\n%s\n\n(This is a reply. Do not answer it unless you have a new request.)\n[end of reply from %s to %s]' "$1" "$3" "$2" "$1" "$3"
}

# A notice needs no answer and asks for nothing (e.g. "X connected to you").
notice_body() {
  printf '[notice from %s to %s via tmux-ask]\n%s\n\n(This is a notice. No reply or action is needed; carry on with what you were doing.)\n[end of notice from %s to %s]' "$1" "$3" "$2" "$1" "$3"
}

# Give pane $1 the name $2, refusing names another pane already holds.
set_name() {
  valid_name "$2" || die "invalid name '$2' (use letters, digits, . _ ~ and -)"
  local owner
  owner="$(find_pane "$2")"
  if [ -n "$owner" ] && [ "$owner" != "$1" ]; then
    die "name '$2' is already used by pane $owner"
  fi
  ensure_agent_ids || return 1
  ensure_agent_id "$1" >/dev/null || return 1
  tmux set-option -p -t "$1" @agent "$2"
}

# Print live peer ids of pane $1, one per line, pruning dead ones.
get_peers() {
  local raw id live=""
  raw="$(tmux display-message -p -t "$1" '#{@peers}' 2>/dev/null)"
  for id in $raw; do
    if pane_alive "$id"; then
      live="$live $id"
      printf '%s\n' "$id"
    fi
  done
  live="${live# }"
  if [ "$live" != "$raw" ]; then
    set_peers "$1" "$live"
  fi
}

set_peers() {
  if [ -n "$2" ]; then
    tmux set-option -p -t "$1" @peers "$2"
  else
    tmux set-option -pu -t "$1" @peers 2>/dev/null || true
  fi
}

is_peer() {
  # Capture first: piping into grep -q can SIGPIPE get_peers under pipefail.
  local peers
  peers="$(get_peers "$1")"
  printf '%s\n' "$peers" | grep -qx -- "$2"
}

add_peer() {
  # The same identity is back; reusing its label must not clear history.
  local name cur
  name="$(pane_agent_id "$2")"
  cur="$(closed_names "$1")"
  case " $cur " in
    *" $name "*) cur="$(printf '%s\n' "$cur" | awk -v n="$name" '{ for (i = 1; i <= NF; i++) if ($i != n) o = o (o ? " " : "") $i } END { print o }')"
      if [ -n "$cur" ]; then tmux set-option -p -t "$1" @closed "$cur"; else tmux set-option -pu -t "$1" @closed; fi ;;
  esac
  is_peer "$1" "$2" && return 0
  set_peers "$1" "$(get_peers "$1" | tr '\n' ' ')$2"
}

remove_peer() {
  set_peers "$1" "$(get_peers "$1" | grep -vx -- "$2" | tr '\n' ' ' | sed 's/ $//')"
}

# Resolve a name, pane id, or tmux target to a pane id.
resolve_pane() {
  local id
  id="$(find_pane "$1")"
  if [ -z "$id" ]; then
    # Only something that looks like a tmux target goes to tmux: %12, 2,
    # 2.1, work:2, work:2.1. tmux matches anything else loosely, by window
    # name too, so a closed agent's name like "blog.example.io-1" resolved
    # to a pane in a window called "blog.example.io": the message went to
    # whoever was there instead of failing.
    is_target "$1" || die "no agent named '$1' (it may have been closed or renamed; see tmux-peers)"
    id="$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null)" || id=""
  fi
  if [ -z "$id" ] || ! pane_alive "$id"; then die "no pane named or targeted by '$1'"; fi
  printf '%s\n' "$id"
}

# Succeeds if $1 is a pane id or a numeric tmux target: %12, 2, 2.1,
# work:2, work:2.1 (session names may hold anything but ':').
is_target() {
  local re='^(%[0-9]+|([^:]+:)?[0-9]+(\.[0-9]+)?)$'
  [[ $1 =~ $re ]]
}

# Space-separated word lists in pane option $2 of pane $1.
add_word() {
  local cur
  cur="$(tmux show-options -pqv -t "$1" "$2" 2>/dev/null)"
  case " $cur " in *" $3 "*) return 0 ;; esac
  tmux set-option -p -t "$1" "$2" "${cur:+$cur }$3"
}

remove_word() {
  local cur
  cur="$(tmux show-options -pqv -t "$1" "$2" 2>/dev/null)"
  cur="$(printf '%s\n' "$cur" | awk -v n="$3" '{ for (i = 1; i <= NF; i++) if ($i != n) o = o (o ? " " : "") $i } END { print o }')"
  if [ -n "$cur" ]; then tmux set-option -p -t "$1" "$2" "$cur"; else tmux set-option -pu -t "$1" "$2" 2>/dev/null || true; fi
}

# IDs of agents the user closed that pane $1 was connected to (@closed).
closed_names() {
  tmux show-options -pqv -t "$1" @closed 2>/dev/null
}

# Before killing pane $1: tell each of its peers, passively, that the user
# closed it, so a later tmux-ask gets a clear answer instead of "no pane".
# $2, if given, is the pane doing the closing; it already knows.
note_closed() {
  local name peer cur
  name="$(pane_agent_id "$1")"
  [ -n "$name" ] || return 0
  for peer in $(get_peers "$1"); do
    [ "$peer" != "${2:-}" ] || continue
    cur="$(closed_names "$peer")"
    case " $cur " in *" $name "*) continue ;; esac
    tmux set-option -p -t "$peer" @closed "${cur:+$cur }$name"
  done
}

# Resolve a name to a connected peer of pane $1.
resolve_peer() {
  local id closed_id
  if [ -z "$(find_pane "$2")" ]; then
    for closed_id in $(closed_names "$1"); do
      [ "$(agent_name_by_id "$closed_id")" != "$2" ] || die "'$2' was closed by the user. Don't reopen it on your own; if the user asks for it back, tmux-spawn --resume $2 brings it back with its conversation. Otherwise, if you still need it, spawn a new sub agent and pass along any report paths it gave you."
    done
  fi
  id="$(resolve_pane "$2")"
  is_peer "$1" "$id" || die "'$2' is not connected to $(label "$1"). If that isn't you, pass --from <your name> (see tmux-peers)"
  printf '%s\n' "$id"
}

# Pane border label: "name ⇄ peer1, peer2" on named panes, blank on others.
BORDER_FORMAT='#{?#{@agent}, #[bold]#{@agent}#[nobold]#{?#{@peer_names}, ⇄ #{@peer_names}, (not connected)} ,}'

# Store each named pane's peer names in @peer_names for the border label,
# and show a border line only in windows that hold named panes.
refresh_labels() {
  local panes id peer n names win agents
  panes="$(tmux list-panes -a -F '#{pane_id} #{@agent}' | awk 'NF == 2 && !seen[$1]++ { print $1 }')"
  for id in $panes; do
    names=""
    for peer in $(get_peers "$id"); do
      n="$(pane_name "$peer")"
      names="${names:+$names, }${n:-$peer}"
    done
    tmux set-option -p -t "$id" @peer_names "$names"
  done

  for win in $(tmux list-windows -a -F '#{window_id}' | sort -u); do
    agents="$(tmux list-panes -t "$win" -F '#{@agent}')"
    if [ -n "$(printf '%s' "$agents" | tr -d '\n')" ]; then
      tmux set-option -w -t "$win" pane-border-status top
      tmux set-option -w -t "$win" pane-border-format "$BORDER_FORMAT"
      tmux set-option -w -t "$win" @agents_border 1
    elif [ "$(tmux show-options -wqv -t "$win" @agents_border)" = 1 ]; then
      tmux set-option -wu -t "$win" pane-border-status
      tmux set-option -wu -t "$win" pane-border-format
      tmux set-option -wu -t "$win" @agents_border
    fi
  done
}

label() {
  local name
  name="$(pane_name "$1")"
  printf '%s (%s)' "${name:-unnamed}" "$1"
}

# Session records use hidden agent IDs as filenames. name is a label;
# id remains the Claude/Codex conversation ID. parent is an agent ID,
# parent_name is a display snapshot. agent_id explicitly marks the format.
sessions_dir() {
  local sock="${TMUX:-default}"
  sock="${sock%%,*}"; sock="${sock##*/}"
  printf '%s/tmux-agents/%s/sessions\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "${sock:-default}"
}

# Identity helpers never run merely from sourcing this file.
valid_agent_id() {
  [ "${#1}" -eq 13 ] || return 1
  case "$1" in a*) ;; *) return 1 ;; esac
  case "${1#a}" in *[!0-9a-f]*) return 1 ;; esac
}

new_agent_id() {
  local aid dir
  dir="$(sessions_dir)"
  while :; do
    aid="a$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" || return 1
    valid_agent_id "$aid" || return 1
    [ ! -e "$dir/$aid" ] && [ -z "$(find_pane_by_id "$aid")" ] || continue
    printf '%s\n' "$aid"
    return 0
  done
}

pane_agent_id() {
  tmux display-message -p -t "$1" '#{@agent_id}' 2>/dev/null
}

find_pane_by_id() {
  valid_agent_id "$1" || return 1
  tmux list-panes -a -F '#{pane_id} #{@agent_id}' | awk -v id="$1" '$2 == id { print $1; exit }'
}

_ensure_agent_id_locked() {
  local pane="$1" requested="${2:-}" aid owner
  pane_alive "$pane" || return 1
  aid="$(pane_agent_id "$pane")"
  if [ -n "$requested" ]; then
    valid_agent_id "$requested" || return 1
    [ -z "$aid" ] || [ "$aid" = "$requested" ] || return 1
    owner="$(find_pane_by_id "$requested")"
    [ -z "$owner" ] || [ "$owner" = "$pane" ] || return 1
    aid="$requested"
  elif ! valid_agent_id "$aid"; then
    aid="$(new_agent_id)" || return 1
  fi
  tmux set-option -p -t "$pane" @agent_id "$aid" || return 1
  printf '%s\n' "$aid"
}

# Print the pane's stable ID. An explicit ID restores a closed identity;
# refuse to overwrite another identity or adopt an ID already live elsewhere.
ensure_agent_id() {
  local aid
  aid="$(pane_agent_id "$1")" || return 1
  if valid_agent_id "$aid"; then
    [ -z "${2:-}" ] || [ "$aid" = "$2" ] || return 1
    printf '%s\n' "$aid"
    return 0
  fi
  # Expanded by the child shell, Perl, or generated script, not this shell.
  # shellcheck disable=SC2016
  agent_identity_lock exclusive /bin/bash -c '. "$1"; _ensure_agent_id_locked "$2" "$3"' \
    identity "${BASH_SOURCE[0]}" "$1" "${2:-}"
}

agent_name_by_id() {
  local pane
  valid_agent_id "$1" || return 1
  pane="$(find_pane_by_id "$1")"
  if [ -n "$pane" ]; then pane_name "$pane"; else record_get "$1" name; fi
}

record_ids_by_name() {
  local dir f
  dir="$(sessions_dir)"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    valid_agent_id "${f##*/}" || continue
    [ "$(record_get "${f##*/}" name)" != "$1" ] || printf '%s\n' "${f##*/}"
  done
}

# Call BEFORE a queue shared lock, never upgrade shared -> exclusive.
# The optional queue root exists for isolated migration tests, not settings.
# A completed check uses only builtins (including sessions_dir).
ensure_agent_ids() {
  local dir
  dir="$(sessions_dir)"
  [ ! -f "$dir/.ids-v1" ] || return 0
  # Expanded by the child shell, Perl, or generated script, not this shell.
  # shellcheck disable=SC2016
  agent_identity_lock exclusive /bin/bash -c '. "$1"; _migrate_agent_ids_locked "$2"' \
    migrate "${BASH_SOURCE[0]}" "${1:-}"
}

# Caller holds identity EX lock. Journal the original names/options before
# replacing anything; replay it until the final marker is written. The journal
# also disambiguates legacy names that happen to look exactly like agent IDs.
_migrate_agent_ids_locked() {
  local dir root sock
  dir="$(sessions_dir)"
  [ ! -f "$dir/.ids-v1" ] || return 0
  root="${1:-/tmp/tmux-agents-$(id -u)/queue}"
  sock="${TMUX:-default}"; sock="${sock%%,*}"; sock="${sock##*/}"
  mkdir -p "$dir" || return 1
  perl -MFile::Temp=tempfile,tempdir -MFile::Copy=copy -MJSON::PP -e '
    use strict; use warnings;
    my ($dir, $root, $sock) = @ARGV;
    sub read_file {
      my ($f) = @_; open(my $h, "<", $f) or die "$f: $!";
      local $/; my $text = <$h>; close $h; return defined($text) ? $text : "";
    }
    sub atomic {
      my ($f, $text) = @_;
      my ($h, $tmp) = tempfile(".ids-write.XXXXXX", DIR => ($f =~ m{^(.*)/} ? $1 : "."), UNLINK => 0);
      print {$h} $text or die "$tmp: $!"; close($h) or die "$tmp: $!";
      rename($tmp, $f) or die "$tmp -> $f: $!";
    }
    sub fields {
      my ($text) = @_; my %v;
      for (split /\n/, $text) { $v{$1} = $2 if /^([^=]+)=(.*)$/; }
      return \%v;
    }
    sub replace_fields {
      my ($text, $values) = @_;
      my @lines = grep { !/^([^=]+)=/ || !exists $values->{$1} } split /\n/, $text;
      push @lines, map { $_ . "=" . $values->{$_} } grep { length $values->{$_} } sort keys %$values;
      return join("\n", @lines) . "\n";
    }
    sub tmux_set {
      my ($pane, $key, $value) = @_;
      system("tmux", "set-option", "-p", "-t", $pane, $key, $value) == 0 or die "tmux set $pane $key failed";
    }
    open(my $ph, "-|", "tmux", "list-panes", "-a", "-F", "#{pane_id}\t\#{\@agent}\t\#{\@agent_id}\t\#{\@awaiting}\t\#{\@closed}") or die "tmux: $!";
    my (%panes, %used, %live);
    while (<$ph>) {
      chomp; my ($p, $name, $id, $awaiting, $closed) = split /\t/, $_, -1;
      $panes{$p} = {name=>$name, id=>$id, awaiting=>$awaiting, closed=>$closed};
      $used{$id} = 1 if length $id;
      $live{$name} = $p if length $name;
    }
    close($ph) or die "tmux snapshot failed";
    opendir(my $dh, $dir) or die "$dir: $!";
    my @files = sort grep { !/^\./ && -f "$dir/$_" } readdir($dh); closedir($dh);
    # Publish a complete, permanent snapshot before any migration writes.
    # A killed copy leaves only a staging directory; retry copies the still
    # untouched records afresh. Never replace an already published backup.
    my $backup = "$dir/.pre-ids-v1";
    if (!-d $backup) {
      die "migration journal exists without original backup: $dir" if -e "$dir/.ids-journal";
      my $stage = tempdir(".pre-ids-v1.XXXXXX", DIR => $dir, CLEANUP => 0);
      for my $file (@files) {
        copy("$dir/$file", "$stage/$file") or die "backup $file: $!";
      }
      rename($stage, $backup) or die "publish backup $backup: $!";
    }
    $used{$_} = 1 for @files;
    sub fresh_id {
      while (1) {
        open(my $random, "<", "/dev/urandom") or die "urandom: $!";
        read($random, my $bytes, 6) == 6 or die "short random read"; close($random);
        my $id = "a" . unpack("H*", $bytes);
        next if $used{$id}; $used{$id} = 1; return $id;
      }
    }
    my $journal = "$dir/.ids-journal";
    my $plan;
    if (-f $journal) { $plan = decode_json(read_file($journal)); }
    else {
      $plan = {names=>{}, records=>[], panes=>{}};
      # Existing new-format records recover mappings even if an old record
      # was already deleted by an interrupted conversion.
      for my $file (@files) {
        my $v = fields(read_file("$dir/$file"));
        if ($file =~ /^a[0-9a-f]{12}$/ && ($v->{agent_id}//"") eq $file) {
          $plan->{names}{$v->{name}} = $file if length($v->{name}//"");
        }
      }
      for my $p (sort keys %panes) {
        my $v = $panes{$p}; next unless length $v->{name};
        my $id = $v->{id} =~ /^a[0-9a-f]{12}$/ ? $v->{id} : ($plan->{names}{$v->{name}} // fresh_id());
        $plan->{names}{$v->{name}} = $id;
        $plan->{panes}{$p} = {%$v, id=>$id};
      }
      for my $file (@files) {
        my $text = read_file("$dir/$file"); my $v = fields($text);
        next if $file =~ /^a[0-9a-f]{12}$/ && ($v->{agent_id}//"") eq $file;
        my $id = $plan->{names}{$file} // fresh_id();
        $plan->{names}{$file} = $id;
        push @{$plan->{records}}, {old=>$file, id=>$id, text=>$text};
      }
      # Also capture unnamed panes options, which may reference named agents.
      for my $p (keys %panes) { $plan->{panes}{$p} //= $panes{$p}; }
      atomic($journal, encode_json($plan));
    }
    my $names = $plan->{names};
    for my $r (@{$plan->{records}}) {
      my $v = fields($r->{text}); my %updates = (agent_id=>$r->{id}, name=>$r->{old});
      if (length($v->{parent}//"")) {
        $updates{parent_name} = $v->{parent};
        $updates{parent} = $names->{$v->{parent}} // "";
      }
      atomic("$dir/$r->{id}", replace_fields($r->{text}, \%updates));
      # Do not delete before replacement is complete, including same-name
      # id-shaped legacy records (fresh IDs never reuse any source filename).
      unlink("$dir/$r->{old}") or die "unlink $r->{old}: $!" if -f "$dir/$r->{old}" && $r->{old} ne $r->{id};
    }
    for my $p (sort keys %{$plan->{panes}}) {
      next unless exists $panes{$p};
      my $v = $plan->{panes}{$p};
      tmux_set($p, "\@agent_id", $v->{id}) if length $v->{name};
      for my $opt (qw(awaiting closed)) {
        my %seen; my @ids;
        for my $name (split /\s+/, $v->{$opt}) {
          my $id = $names->{$name} // ($name =~ /^a[0-9a-f]{12}$/ && $used{$name} ? $name : "");
          push @ids, $id if length($id) && !$seen{$id}++;
        }
        tmux_set($p, "\@$opt", join(" ", @ids));
      }
    }
    # Flat legacy metadata has no reliable server owner. Never inspect it.
    # Only metadata queued or undelivered on this server may be migrated.
    my @meta;
    my $q = "$root/$sock";
    if (-d $q) {
      opendir(my $qh, $q) or die "$q: $!";
      @meta = map { "$q/$_" } grep { /\.meta$/ && -f "$q/$_" } readdir($qh);
      closedir($qh);
    }
    for my $f (@meta) {
      my $text = read_file($f); my $v = fields($text); my %updates;
      for my $side (qw(from to)) {
        next if length($v->{"${side}_id"}//"");
        my $id = $names->{$v->{"${side}_name"}//""};
        $updates{"${side}_id"} = $id if defined $id;
      }
      atomic($f, replace_fields($text, \%updates)) if keys %updates;
    }
    atomic("$dir/.ids-v1", "1\n");
    unlink($journal) or die "unlink journal: $!";
  ' "$dir" "$root" "${sock:-default}"
}

# record_get AGENT_ID KEY: print the value, empty if unset.
record_get() {
  valid_agent_id "$1" || return 1
  local f
  f="$(sessions_dir)/$1"
  [ -f "$f" ] || return 0
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { printf "%s", v }' "$f"
}

# record_set AGENT_ID KEY VALUE: set one key (empty VALUE removes it).
record_set() {
  valid_agent_id "$1" || return 1
  local d
  d="$(sessions_dir)"
  mkdir -p "$d"
  perl -MFcntl=:flock -e '
    my ($dir, $id, $key, $value) = @ARGV;
    open(my $lock, ">>", "$dir/.record-$id.lock") or die "$!";
    flock($lock, LOCK_EX) or die "$!";
    my %v;
    if (open(my $in, "<", "$dir/$id")) {
      while (<$in>) { chomp; my ($k, $v) = split /=/, $_, 2; $v{$k} = $v if defined $v }
    }
    $v{agent_id} = $id;
    if (length $value) { $v{$key} = $value } else { delete $v{$key} }
    my $tmp = "$dir/.rec-$$";
    open(my $out, ">", $tmp) or die "$!";
    print $out "$_=$v{$_}\n" for sort keys %v;
    close($out) or die "$!";
    rename($tmp, "$dir/$id") or die "$!";
  ' "$d" "$1" "$2" "$3"
}

# Accounting is event driven, never part of the list build. A legacy pane
# starts at its first event: missing timestamps never imply historical work.
# @turn_start is the active interval only. @turn_work accumulates its logical
# turn across pauses; @turn_active survives permission, message and needs-you
# waits. Only done, idle or close completes that turn and updates last_turn.
agent_set_state() { _agent_work "$1" state "$2" "${3:-}"; }
agent_save_work() { _agent_work "$1" save "" "${2:-}"; }
agent_restore_work() { _agent_work "$1" restore "$2" "${3:-}"; }
# VALUE is an epoch marker, or empty to clear. Both overlays share the lock.
agent_set_wait() { _agent_work "$1" "$2" "$3" "${4:-}"; }
# Internal guarded transitions keep done/idle precedence inside the same lock.
agent_report_state() { _agent_work "$1" report "" "${2:-}"; }
agent_turn_state() { _agent_work "$1" "$2" "${3:-}" "${4:-}"; }
agent_start_work() { _agent_work "$1" spawn "$2" "${3:-}"; }

_agent_work() {
  local d
  d="$(sessions_dir)"
  mkdir -p "$d"
  perl -MFcntl=:flock -e '
    use strict; use warnings;
    my ($dir, $pane, $op, $value, $now) = @ARGV;
    die "invalid pane" unless $pane =~ /^%[0-9]+$/;
    die "invalid clock" if length($now) && $now !~ /^[0-9]+$/;
    open(my $lock, ">>", "$dir/.work-$pane.lock") or die "$!";
    flock($lock, LOCK_EX) or die "$!";
    $now = time unless length $now;
    my @keys = qw(state state_since worked last_turn turns turn_start turn_work turn_active started perm_since msg_waiting_since work_closed work_restored agent_id agent activity);
    my $format = "#{pane_id}\t" . join("\t", map { "\#{\@$_}" } @keys);
    open(my $in, "-|", "tmux", "display-message", "-p", "-t", $pane, $format) or die "$!";
    my $row = do { local $/; <$in> } // ""; close($in); chomp $row;
    my ($found, @vals) = split /\t/, $row, scalar(@keys)+1;
    exit 0 unless $found eq $pane;
    my %v; @v{@keys} = @vals;
    my %before = %v;
    sub number { defined($_[0]) && $_[0] =~ /^[0-9]+$/ }
    sub effective {
      return "closed" if $v{work_closed};
      return "permission" if $v{perm_since};
      return "message" if $v{msg_waiting_since};
      return $v{state} || "working";
    }
    my $old = effective();
    $op = "checkpoint" if $op eq "spawn" && number($v{started});
    # Never infer an interval from a legacy working state without turn_start.
    if ($op eq "restore") {
      die "invalid agent id" unless $value =~ /^a[0-9a-f]{12}$/;
      exit 0 if ($v{work_restored} // "") eq $value;
      $v{work_restored} = $value;
      if (open(my $rec, "<", "$dir/$value")) {
        my %r;
        while (<$rec>) { chomp; my ($k, $val) = split /=/, $_, 2; $r{$k} = $val if defined $val }
        for (qw(started worked last_turn turns)) { $v{$_} = number($r{$_}) ? $r{$_} : "" }
      }
      $v{state} = "done"; $v{state_since} = $now;
      $v{turn_start} = $v{turn_work} = $v{turn_active} = "";
      $v{work_closed} = $v{perm_since} = $v{msg_waiting_since} = "";
    } else {
      if ($op eq "state") { $v{state} = $value }
      elsif ($op eq "spawn") {
        $v{started} = $now; $v{worked} = $v{turns} = 0;
        $v{state} = $value;
      }
      elsif ($op eq "report") {
        $v{state} = "working" unless $v{state} eq "done";
        $v{perm_since} = "";
      }
      elsif ($op eq "start") {
        $v{state} = "working" if $v{state} eq "needs_you";
        $v{perm_since} = "";
      }
      elsif ($op eq "end") {
        $v{state} = $value if length($value) && $v{state} !~ /^(done|idle)$/;
        $v{perm_since} = "";
      }
      elsif ($op eq "perm" || $op eq "message") {
        my $key = $op eq "perm" ? "perm_since" : "msg_waiting_since";
        die "invalid wait timestamp" if length($value) && !number($value);
        # Permission on repeats must not reset its attention timestamp.
        $v{$key} = $op eq "perm" && length($value) && $v{$key} ? $v{$key} : $value;
      }
      elsif ($op eq "save") { $v{work_closed} = 1 }
      elsif ($op eq "checkpoint") { }
      else { die "unknown accounting operation" }
      my $new = effective();
      if (number($v{turn_start}) && $new ne "working") {
        my $elapsed = $now - $v{turn_start}; $elapsed = 0 if $elapsed < 0;
        $v{worked} = (number($v{worked}) ? $v{worked} : 0) + $elapsed;
        $v{turn_work} = (number($v{turn_work}) ? $v{turn_work} : 0) + $elapsed;
        $v{turn_active} = 1;
        $v{turn_start} = "";
      }
      # A terminal semantic state completes the turn even under an overlay.
      if ($v{turn_active} && ($v{work_closed} || $v{state} =~ /^(done|idle)$/)) {
        $v{last_turn} = number($v{turn_work}) ? $v{turn_work} : 0;
        $v{turns} = (number($v{turns}) ? $v{turns} : 0) + 1;
        $v{turn_work} = $v{turn_active} = "";
      }
      if ($new eq "working" && !number($v{turn_start})) {
        unless ($v{turn_active}) {
          $v{turn_active} = 1; $v{turn_work} = 0;
        }
        $v{worked} = 0 unless number($v{worked});
        $v{turns} = 0 unless number($v{turns});
        $v{turn_start} = $now;
      }
      $v{state_since} = $now if $old ne $new || !number($v{state_since});
    }
    my @cmd;
    for my $key (@keys) {
      next if ($v{$key} // "") eq ($before{$key} // "");
      push @cmd, ";" if @cmd;
      push @cmd, "set-option", (length($v{$key} // "") ? "-p" : "-pu"), "-t", $pane, "\@$key";
      push @cmd, $v{$key} if length($v{$key} // "");
    }
    system("tmux", @cmd) == 0 or die "accounting update failed" if @cmd;
    # Persist timing transitions in this same process. Repeated reports do not
    # rewrite unchanged counters; initial/restore checkpoints also bind pane ID.
    my $persist = $op =~ /^(save|spawn|checkpoint|restore)$/;
    for (qw(state_since worked last_turn turns turn_start)) {
      $persist = 1 if ($v{$_} // "") ne ($before{$_} // "");
    }
    if ($persist) {
      my $id = $v{agent_id} || ($op eq "restore" ? $value : "");
      exit 0 unless defined($id) && $id =~ /^a[0-9a-f]{12}$/;
      open(my $rl, ">>", "$dir/.record-$id.lock") or die "$!";
      flock($rl, LOCK_EX) or die "$!";
      my %r;
      if (open(my $rec, "<", "$dir/$id")) {
        while (<$rec>) { chomp; my ($k, $val) = split /=/, $_, 2; $r{$k} = $val if defined $val }
        close $rec;
      }
      $r{agent_id} = $id;
      $r{name} = $v{agent} if length($v{agent} // "");
      # Records split only at the first =; flatten line breaks to prevent keys
      # in activity text from becoming record entries. Preserve literal equals.
      my $activity = $v{activity} // ""; $activity =~ s/[\r\n\t]/ /g;
      if (length $activity) { $r{activity} = $activity } else { delete $r{activity} }
      for (qw(state_since worked last_turn turns turn_start started)) {
        if (number($v{$_})) { $r{$_} = $v{$_} } else { delete $r{$_} }
      }
      $r{pane} = $pane;
      if ($op eq "save") { $r{closed} = $now unless $r{closed} }
      else { delete $r{closed} }
      my $tmp = "$dir/.rec-$$";
      open(my $out, ">", $tmp) or die "$!";
      print $out "$_=$r{$_}\n" for sort keys %r;
      close($out) or die "$!"; rename($tmp, "$dir/$id") or die "$!";
    }
  ' "$d" "$1" "$2" "$3" "$4"
}

# Mark the sub agent in pane $1 closed, if it has a record.
record_closed() {
  local name
  name="$(pane_agent_id "$1")"
  [ -n "$name" ] && [ -f "$(sessions_dir)/$name" ] || return 0
  agent_save_work "$1"
}

# Strict ancestry: only live, exact pane IDs participate. Reject cycles,
# including cycles above the requested ancestor, rather than granting access.
pane_is_descendant() {
  local child="$1" ancestor="$2" cursor="$1" seen=" " found=1
  [ "$child" != "$ancestor" ] || return 1
  pane_alive "$ancestor" && pane_alive "$child" || return 1
  while [ -n "$cursor" ]; do
    case "$cursor" in %*) ;; *) return 1 ;; esac
    case "$seen" in *" $cursor "*) return 1 ;; esac
    pane_alive "$cursor" || return 1
    seen="$seen$cursor "
    [ "$cursor" != "$ancestor" ] || found=0
    cursor="$(tmux show-options -pqv -t "$cursor" @parent)" || return 1
  done
  return "$found"
}

# Snapshot the live ownership graph and print the root's subtree deepest
# first. Missing parents and cycles outside that subtree cannot loop.
pane_subtree() {
  pane_alive "$1" || return 1
  tmux list-panes -a -F '#{pane_id} #{@parent}' | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      for (pane in parent) {
        cursor = pane; depth = 0
        for (key in seen) delete seen[key]
        while (cursor in parent && !seen[cursor]++) {
          if (cursor == root) { print depth, pane; break }
          cursor = parent[cursor]; depth++
        }
      }
    }' | sort -k1,1nr -k2,2 | awk '{ print $2 }'
}

pane_finished() {
  pane_alive "$1" || return 1
  case "$(tmux display-message -p -t "$1" '#{?pane_dead,exited,#{@state}}')" in
    done|exited) return 0 ;;
    *) return 1 ;;
  esac
}

# Queue identity changes serialize against publication, retry and delivery.
# Kernel locks survive exec and are released even if a process is killed.
agent_identity_lock() {
  local mode="$1"; shift
  local root
  root="/tmp/tmux-agents-$(id -u)/queue"
  mkdir -p "$root"
  perl -MFcntl=:flock -e '
    $^F = 255;
    my ($path, $mode) = splice @ARGV, 0, 2;
    open(my $lock, ">>", $path) or die "$path: $!";
    flock($lock, $mode eq "exclusive" ? LOCK_EX : LOCK_SH) or die "flock: $!";
    exec @ARGV; die "exec: $!";
  ' "$root/.identity.lock" "$mode" "$@"
}

# Called under the identity lock. Authorization belongs to the caller.
_rename_agent_locked() {
  local pane="$1" new="$2" old owner dir aid
  _migrate_agent_ids_locked || return 1
  valid_name "$new" || die "invalid name '$new' (use letters, digits, . _ ~ and -)"
  pane_alive "$pane" || die "pane $pane no longer exists"
  old="$(pane_name "$pane")"
  aid="$(_ensure_agent_id_locked "$pane")" || return 1
  [ "$old" != "$new" ] || { printf '%s\n' "$old"; return 0; }
  owner="$(find_pane "$new")"
  [ -z "$owner" ] || die "name '$new' is already used by pane $owner"
  dir="$(sessions_dir)"
  if [ -f "$dir/$aid" ]; then record_set "$aid" name "$new" || return 1; fi
  tmux set-option -p -t "$pane" @agent "$new" || return 1
  refresh_labels || return 1
  printf '%s\n' "$old"
}

# FINAL_NAME is already expanded, including for tmux-connect --as.
rename_agent() {
  local pane="$1" new="$2" old peer lib ask
  lib="${BASH_SOURCE[0]}"
  ask="$(dirname "$lib")/tmux-ask"
  # Expanded by the child shell, Perl, or generated script, not this shell.
  # shellcheck disable=SC2016
  old="$(agent_identity_lock exclusive /bin/bash -c '. "$1"; _rename_agent_locked "$2" "$3"' rename "$lib" "$pane" "$new")" || return 1
  [ "$old" != "$new" ] || return 0
  "$ask" --system-notice "$pane" "you are now $new; pass --from $new from now on" || return 1
  for peer in $(get_peers "$pane"); do
    "$ask" --system-notice "$peer" "${old:-$pane} is now $new" || return 1
  done
}

# Format a supplied name without choosing a collision suffix. --exact wins
# over the local environment, the tmux option, and the prefixed default.
format_given_name() {
  local kind="$1" dir="$2" given="$3" exact="$4" format prefix
  if [ "$exact" = 1 ]; then format=exact
  else settings_get format TMUX_AGENTS_NAME_FORMAT @tmux_agents_name_format prefixed; fi
  case "${format:-prefixed}" in
    exact)
      valid_name "$given" || die "invalid name '$given' (use letters, digits, . _ ~ and -)"
      printf '%s\n' "$given" ;;
    prefixed)
      given="$(sanitize_name "$given")" || return 1
      prefix="$(name_for "$kind" "$dir")" || return 1
      prefix="${prefix%-*}-"
      case "$given" in "$prefix"*) printf '%s\n' "$given" ;; *) printf '%s%s\n' "$prefix" "$given" ;; esac ;;
    *) die "invalid name format '$format' (use exact or prefixed)" ;;
  esac
}

# Cache one option snapshot per shell. Decode tmux's quoted output as data,
# never eval it; NUL-delimited fields retain spaces, quotes and newlines.
settings_load() {
  [ "${_TMUX_SETTINGS_LOADED:-0}" = 1 ] && return 0
  _TMUX_SETTINGS_LOADED=1
  _TMUX_SETTING_KEYS=() _TMUX_SETTING_VALUES=()
  local _settings_key _settings_value _settings_index=0
  while IFS= read -r -d '' _settings_key && IFS= read -r -d '' _settings_value; do
    _TMUX_SETTING_KEYS[_settings_index]="$_settings_key"
    _TMUX_SETTING_VALUES[_settings_index]="$_settings_value"
    _settings_index=$((_settings_index + 1))
  done < <(tmux show-options -g 2>/dev/null | perl -ne '
    next unless /^(@tmux_agents_\S+)\s+(.*)$/;
    my ($key, $value) = ($1, $2);
    if ($value =~ /^"(.*)"$/s) {
      $value = $1;
      $value =~ s/\\([0-7]{3}|.)/$1 =~ m{^[0-7]{3}$} ? chr(oct($1)) : $1 eq "n" ? "\n" : $1 eq "r" ? "\r" : $1 eq "t" ? "\t" : $1/ge;
    }
    print $key, "\0", $value, "\0";
  ')
}

# Assign to the caller's variable; direct calls retain the snapshot cache.
option_get() {
  settings_load
  local _option_i=0 _option_value="$3"
  while [ "$_option_i" -lt "${#_TMUX_SETTING_KEYS[@]}" ]; do
    if [ "${_TMUX_SETTING_KEYS[$_option_i]}" = "$2" ]; then
      _option_value="${_TMUX_SETTING_VALUES[$_option_i]}"
      [ -n "$_option_value" ] || _option_value="$3"
      break
    fi
    _option_i=$((_option_i + 1))
  done
  printf -v "$1" '%s' "$_option_value"
}

settings_get() {
  local _settings_env="$2"
  if [ -n "$_settings_env" ] && [ -n "${!_settings_env:-}" ]; then
    printf -v "$1" '%s' "${!_settings_env}"
  else
    option_get "$1" "$3" "$4"
  fi
}

# Resolve profile=CODEX_HOME mappings exactly as tmux-spawn does. A direct
# call preserves settings_get's option snapshot; no running tmux is required.
resolve_codex_homes() {
  local _codex_homes_value _codex_homes_global
  settings_get _codex_homes_value TMUX_AGENTS_CODEX_HOMES @tmux_agents_codex_homes ""
  if [ -z "$_codex_homes_value" ] && [ -n "${TMUX:-}" ]; then
    _codex_homes_global="$(tmux show-environment -g TMUX_AGENTS_CODEX_HOMES 2>/dev/null || true)"
    case "$_codex_homes_global" in
      TMUX_AGENTS_CODEX_HOMES=?*) _codex_homes_value="${_codex_homes_global#*=}" ;;
    esac
  fi
  printf -v "$1" '%s' "$_codex_homes_value"
}

# Hooks after removal cannot read the removed panes. Close their records using
# one snapshot, retaining checkpointed work without guessing the lost interval.
agent_sweep_closed() {
  local d
  d="$(sessions_dir)"
  [ -d "$d" ] || return 0
  perl -MFcntl=:flock -e '
    use strict; use warnings;
    my ($dir) = @ARGV;
    sub read_record {
      my ($file) = @_; my %r;
      if (open(my $in, "<", $file)) {
        while (<$in>) { chomp; my ($k,$v) = split /=/, $_, 2; $r{$k}=$v if defined $v }
        close $in;
      }
      return %r;
    }
    # Read candidates before snapshotting panes. After locking, verify the
    # binding is unchanged, so a concurrent resume is never closed by an old
    # snapshot that preceded creation of its new pane.
    opendir(my $dh, $dir) or die "$!";
    my %candidate;
    for my $id (readdir $dh) {
      next unless $id =~ /^a[0-9a-f]{12}$/;
      my %r=read_record("$dir/$id");
      next if $r{closed} || ($r{pane} // "") !~ /^%[0-9]+$/;
      $candidate{$id}=$r{pane};
    }
    closedir $dh;
    exit 0 unless %candidate;
    open(my $panes, "-|", "tmux", "list-panes", "-a", "-F", "#{pane_id}") or die "$!";
    my %live; while (<$panes>) { chomp; $live{$_}=1 }
    close($panes) or exit 0; # A failed query is not evidence of disappearance.
    my $now=time;
    for my $id (sort keys %candidate) {
      next if $live{$candidate{$id}};
      open(my $lock, ">>", "$dir/.record-$id.lock") or die "$!";
      flock($lock, LOCK_EX) or die "$!";
      my %r=read_record("$dir/$id");
      next if $r{closed} || ($r{pane} // "") ne $candidate{$id};
      $r{closed}=$now;
      delete $r{turn_start};
      my $tmp="$dir/.rec-$$";
      open(my $out, ">", $tmp) or die "$!";
      print $out "$_=$r{$_}\n" for sort keys %r;
      close($out) or die "$!";
      rename($tmp,"$dir/$id") or die "$!";
    }
  ' "$d"
}
