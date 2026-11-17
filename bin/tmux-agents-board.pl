#!/usr/bin/env perl
# One pane snapshot, one read per needed record, no per-agent tmux queries.
use strict;
use warnings;
use Cwd qw(getcwd);
use MIME::Base64 qw(decode_base64);
use Storable qw(retrieve store);
my ($here) = @ARGV;
my $mission_dir=$ENV{BOARD_MISSION_DIR} // '';
(my $project=$mission_dir) =~ s{.*/}{};
if ($project eq '') {
 print 'board: cannot resolve a project for ', (getcwd() // $ENV{PWD} // '.'), "\n";
 exit 0;
}
my @fields = ('P', '#{pane_id}', '#{?@agent,#{@agent},-}', '#{pane_dead}',
 '#{?@perm_since,#{@perm_since},-}', '#{?@state,#{@state},-}', '#{?@parent,#{@parent},-}',
 '#{session_name}', '#{?@activity,#{@activity},-}', '#{pane_current_path}',
 '#{session_name}:#{window_index}', '#{?@attention_since,#{@attention_since},-}',
 '#{?@msg_waiting_since,#{@msg_waiting_since},-}', '#{window_id}', '#{?@agent_id,#{@agent_id},-}',
 '#{@state_since}', '#{@worked}', '#{@last_turn}', '#{@turns}', '#{@turn_start}', '#{@started}',
 '#{?@member,#{@member},0}', '#{?@tracked,#{@tracked},0}', '#{?@shell,#{@shell},0}',
 '-', '-', '-', '-', '#{pane_width}', '#{pane_height}');
open my $tmux, '-|', 'tmux', 'list-panes', '-a', '-F', join("\t", @fields) or die "tmux: $!\n";
my @rows;
while (<$tmux>) { chomp; push @rows, [split /\t/, $_, -1]; }
close $tmux or die "tmux-agents board: cannot read pane snapshot\n";
my $prefix = $ENV{TMUX_AGENTS_PREFIX} || 'agents';
my $cache=$ENV{BOARD_PROJECT_CACHE};
my %projects=($cache && -s $cache) ? %{retrieve($cache)} : ();
sub project {
 my ($path) = @_;
 return $projects{$path} if exists $projects{$path};
 open my $resolve, '-|', 'bash', '-c',
  '. "$1/lib.sh"; mission_directory "$2"', 'board-project', $here, $path
  or die "project: $!\n";
 my $dir=<$resolve> // ''; close $resolve or die "cannot resolve project\n";
 chomp $dir;
 $dir =~ s{.*/}{};
 return $projects{$path}=$dir;
}
sub row_project {
 my ($r)=@_;
 return substr($r->[7],length($prefix)+1) if index($r->[7],"$prefix-")==0;
 return project($r->[9]);
}
my ($self)=grep { $_->[1] eq ($ENV{TMUX_PANE}//'') } @rows;
my $width=$self ? $self->[28] : ($ENV{COLUMNS}//80);
my $state=($ENV{XDG_STATE_HOME}||"$ENV{HOME}/.local/state").'/tmux-agents';
my $socket=(split /,/, $ENV{TMUX}//'')[0] // ''; $socket =~ s{.*/}{};
my @data;
for my $r (@rows) {
 next if $r->[9] eq '';
 push @data, join("\t",@$r[0..27]);
 next if $r->[2] eq '-' || $r->[3] eq '1' || $r->[23] eq '1';
 my %record;
 if ($r->[14] =~ /^a[0-9a-f]+$/ && open(my $fh,'<',"$state/$socket/sessions/$r->[14]")) {
  while (<$fh>) { chomp; my ($k,$v)=split /=/,$_,2; $record{$k}=$v if defined $v }
  close $fh;
 }
 my $kind=$record{kind} // ((split /-/, $r->[2])[0]);
 my @args=split /\0/,decode_base64($record{cli_args}//'');
 my $model='default';
 for (my $i=0;$i<@args;$i++) {
  $model=$args[$i+1] if $args[$i] eq '--model' && $i+1<@args;
  $model=$1 if $args[$i] =~ /^--model=(.+)$/;
 }
 for ($kind,$model) { s/[\x00-\x1f\x7f]/ /g }
 push @data,join("\t",'A',$r->[1],$kind,$model,row_project($r));
}
my $missing=1;

if (opendir my $dir, $mission_dir) {
 my @files=sort { length($a) <=> length($b) || $a cmp $b }
           grep { /^M[1-9][0-9]*\.mission$/ } readdir $dir;
 closedir $dir;
 for my $file (@files) {
  open my $mission,'<',"$mission_dir/$file" or next;
  my %record;
  while (<$mission>) {
   chomp; my ($key,$value)=split /=/,$_,2;
   $record{$key}=$value if defined $value;
  }
  close $mission;
  # Ignore incomplete or malformed records, including interrupted legacy writes.
  next if grep { !defined($record{$_}) || $record{$_} eq '' || $record{$_} =~ /[\t\r\n]/ }
               qw(id title owner status created updated);
  next unless "$record{id}.mission" eq $file && $record{created} =~ /^[0-9]+$/ && $record{updated} =~ /^[0-9]+$/;
  $missing=0;
  push @data,join("\t",'M',@record{qw(id title owner status updated)});
 }
}
push @data,join("\t",'B',$project,$width,$missing,($ENV{BOARD_WATCH} && $self ? $self->[29] : 0));
store(\%projects,$cache) if $cache;
$ENV{LIST_NOW}=time;
$ENV{LIST_BOARD}=1; $ENV{LC_ALL}='C';
open my $awk,'|-','awk','-f',"$here/tmux-agents-list.awk" or die "awk: $!\n";
print {$awk} join("\n",@data),"\n";
close $awk or die "tmux-agents board: rendering failed\n";
