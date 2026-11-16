#!/usr/bin/env bash
# Quiet notes are scoped to the server and stable receiver identity.
notes_dir() {
  local dir
  dir="$(sessions_dir)"
  printf '%s/notes\n' "${dir%/sessions}"
}

# One receiver lock covers publication, snapshots, reading and expiry. JSON
# records never change. Sequence and read cursor survive retention pruning.
_notes_store() {
  local mode="$1" receiver="$2" dir
  shift 2
  valid_agent_id "$receiver" || return 1
  dir="$(notes_dir)/$receiver"
  (umask 077; mkdir -p "$dir") || return 1
  perl -MJSON::PP -MTime::HiRes=time -MFcntl=:flock -MEncode=decode -e '
    use strict; use warnings;
    my ($dir, $mode, @args) = @ARGV;
    umask 0077;
    open(my $lock, ">>", "$dir/.lock") or die "notes lock: $!\n";
    flock($lock, LOCK_EX) or die "notes lock: $!\n";
    my $now = time;
    sub atomic {
      my ($path, $value) = @_;
      my $tmp = "$path.$$";
      open(my $out, ">", $tmp) or die "notes write: $!\n";
      print {$out} encode_json($value) or die "notes write: $!\n";
      close($out) or die "notes close: $!\n";
      rename($tmp, $path) or die "notes publish: $!\n";
    }
    sub counter {
      my ($path) = @_;
      return 0 unless -e $path;
      open(my $fh, "<", $path) or die "notes counter: $!\n";
      my $value = do {local $/; <$fh>}; close($fh);
      die "invalid notes counter\n" unless defined($value) && $value =~ /^\d+\s*$/;
      return 0+$value;
    }
    my $sequence = counter("$dir/.sequence");
    my $cursor = counter("$dir/.cursor");
    sub advance_cursor {
      my ($through) = @_;
      die "invalid note cutoff\n" unless defined($through) && $through =~ /^\d+$/;
      $through = $sequence if $through > $sequence;
      atomic("$dir/.cursor", 0+$through) if $through > $cursor;
    }
    opendir(my $dh, $dir) or die "notes directory: $!\n";
    my @notes;
    for my $file (sort readdir($dh)) {
      next unless $file =~ /^m[0-9a-f]+\.json$/;
      open(my $fh, "<", "$dir/$file") or next;
      my $raw = do {local $/; <$fh>}; close($fh);
      my $note = eval {decode_json($raw)};
      next unless ref($note) eq "HASH" && defined $note->{at};
      if ($note->{at} < $now - 604800) {unlink("$dir/$file"); next}
      push @notes, $note;
    }
    closedir($dh);
    if ($mode eq "write") {
      my ($from_id, $name, $message_id, $at) = @args;
      die "invalid note ID\n" unless $message_id =~ /^m[0-9a-f]+$/;
      # Publication time is display/filter data; sequence is the read boundary.
      $at = time unless defined($at) && length($at);
      die "invalid note timestamp\n" unless $at =~ /^\d+(?:\.\d+)?$/;
      my $text = do {local $/; <STDIN>};
      die "empty note\n" unless defined($text) && length($text);
      die "note already exists\n" if -e "$dir/$message_id.json";
      # Reserve first: an interrupted publication may leave a gap, never reuse.
      my $id = $sequence + 1;
      atomic("$dir/.sequence", $id);
      atomic("$dir/.cursor", $cursor) unless -e "$dir/.cursor";
      atomic("$dir/$message_id.json", {id=>$id, message_id=>$message_id, at=>0+$at, from_id=>$from_id,
        from_name=>decode("UTF-8", $name), text=>decode("UTF-8", $text)});
      exit;
    }
    if ($mode eq "mark-read") {
      advance_cursor($args[0]);
      exit;
    }
    my ($after, $all, $keep, $name) = @args;
    $after ||= 0;
    @notes = sort {$a->{id} <=> $b->{id}}
      grep {$_->{at} > $after && ($all || $_->{id} > $cursor)} @notes;
    if ($mode eq "count") { print scalar(@notes), "\n"; exit }
    my %groups;
    for my $n (@notes) {push @{$groups{$n->{from_name}}}, $n}
    sub first_line {
      my ($text) = @_; $text =~ s/[\r\n].*//s;
      return length($text) > 80 ? substr($text, 0, 80) . "..." : $text;
    }
    my @senders = map {
      my $g = $groups{$_}; my $last = $g->[-1];
      {name=>$_, count=>scalar(@$g), latest=>first_line($last->{text}), latest_at=>$last->{at}}
    } sort keys %groups;
    my $latest = @notes ? $notes[-1] : {};
    if ($mode eq "snapshot") {
      print encode_json({count=>scalar(@notes), senders=>\@senders,
        latest_id=>0+($latest->{id}//0), latest=>first_line($latest->{text}//""), latest_at=>0+($latest->{at}//0), latest_from=>$latest->{from_name}//""}), "\n";
      exit;
    }
    binmode STDOUT, ":encoding(UTF-8)";
    if ($mode eq "summary") {
      exit unless @notes;
      print "agent notes: ", scalar(@notes), " unread; ",
        join("; ", map {my @t = localtime($_->{latest_at}); sprintf("%s (%d), latest %02d:%02d: %s", $_->{name}, $_->{count}, $t[2], $t[1], $_->{latest})} @senders),
        ". Read with: tmux-notes --from ", decode("UTF-8", $name), "\n";
      exit;
    }
    die "invalid notes operation\n" unless $mode eq "read";
    for my $sender (sort keys %groups) {
      print "$sender:\n";
      for my $n (sort {$a->{at} <=> $b->{at} || $a->{id} <=> $b->{id}} @{$groups{$sender}}) {
        my @t = localtime($n->{at});
        printf "  %02d:%02d %s [%s] %s\n", $t[2], $t[1], $n->{id}, $n->{message_id}, $n->{text};
      }
    }
    # Only mark the exact successfully printed snapshot, never later arrivals.
    close(STDOUT) or die "notes output: $!\n";
    advance_cursor($latest->{id}) if !$keep && @notes;
  ' "$dir" "$mode" "$@"
}

notes_write() {
  printf '%s' "$5" | _notes_store write "$1" "$2" "$3" "$4" "${6:-}"
}
notes_mark_read() { _notes_store mark-read "$1" "$2"; }
notes_snapshot() { _notes_store snapshot "$1" "${2:-0}" 0 1 ''; }
notes_summary() { _notes_store summary "$1" "${3:-0}" 0 1 "$2"; }

notes_start_digest() {
  local pane
  # here is supplied by each executable sourcing this library.
  # shellcheck disable=SC2154
  [ -x "$here/tmux-agents-notes-digest.sh" ] || return 0
  pane="$(find_pane_by_id "$1")"
  [ -n "$pane" ] || return 0
  "$here/tmux-agents-notes-digest.sh" --start "$1" >/dev/null 2>&1 || true
}
