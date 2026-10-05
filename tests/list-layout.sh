#!/usr/bin/env bash
# Fixed display-cell columns, project labels, time formats, search and preview.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
B="$here/bin"
sock="tmux-list-layout-$$"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-list-layout.XXXXXX")"
unset TMUX TMUX_PANE CLAUDECODE TMUX_AGENTS_KIND TMUX_AGENTS_PINNED
export XDG_STATE_HOME="$tmp/state"
. "$here/tests/helpers/cleanup.sh"
# Invoked by EXIT.
# shellcheck disable=SC2329
cleanup() { cleanup_test_server || return; rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/project-with-a-long-name" "$tmp/shim"
tmux -L "$sock" -f /dev/null new-session -d -s work -c "$tmp/project-with-a-long-name" cat </dev/null
tmux -L "$sock" has-session || { echo 'ABORT: test server not up'; exit 1; }
S="$(tmux -L "$sock" display-message -p '#{socket_path}')"
case "$S" in ''|*/default) echo 'ABORT: unsafe socket'; exit 1 ;; esac
export TMUX="$S,1,0" TMUX_PANE=%0
tmux set -g default-shell /bin/sh
tmux set -p -t %0 @agent main
# Freeze only epoch reads, leaving date formatting available to previews.
LAYOUT_REAL_DATE="$(command -v date)" LAYOUT_NOW="$(date +%s)"
export LAYOUT_REAL_DATE LAYOUT_NOW
cat >"$tmp/shim/date" <<'STUB'
#!/bin/sh
if [ "$#" = 1 ] && [ "$1" = +%s ]; then printf '%s\n' "$LAYOUT_NOW"; else exec "$LAYOUT_REAL_DATE" "$@"; fi
STUB
cat >"$tmp/shim/fzf" <<'STUB'
#!/bin/sh
printf '%s\000' "$@" >"$LAYOUT_FZF_ARGS"
exit 1
STUB
chmod +x "$tmp/shim/date" "$tmp/shim/fzf"
real_fzf="$(command -v fzf || true)"
export PATH="$tmp/shim:$PATH" LAYOUT_FZF_ARGS="$tmp/args"
project="project-with-a-long-name"
parent="$(tmux new-session -d -s "agents-$project" -c "$tmp/$project" -P -F '#{pane_id}' cat </dev/null)"
tmux set -p -t "$parent" @agent "claude-$project-secondary"
tmux set -p -t "$parent" @parent %0
tmux set -p -t "$parent" @state idle
tmux set -p -t "$parent" @state_since "$((LAYOUT_NOW-245))"
child="$(tmux new-window -d -t "agents-$project" -c "$tmp/$project" -P -F '#{pane_id}' cat </dev/null)"
full="codex-$project-investigate-extremely-long-middle-part-tail"
tmux set -p -t "$child" @agent "$full"
tmux set -p -t "$child" @parent "$parent"
tmux set -p -t "$child" @state working
tmux set -p -t "$child" @state_since "$((LAYOUT_NOW-45))"
tmux set -p -t "$child" @worked 3855
tmux set -p -t "$child" @turn_start "$((LAYOUT_NOW-45))"
tmux set -p -t "$child" @started "$((LAYOUT_NOW-86400))"
tmux set -p -t "$child" @last_turn 420
tmux set -p -t "$child" @turns 3
tmux set -p -t "$child" @activity '汉字宽度 ééé 界界界界界界界界界界界界界界界界界界界界界界 tail-must-be-cut'
pinned="$(tmux new-window -d -t "agents-$project" -c "$tmp/$project" -P -F '#{pane_id}' cat </dev/null)"
tmux set -p -t "$pinned" @agent "codex-$project-pinned-tail"
tmux set -p -t "$pinned" @parent "$parent"
tmux set -p -t "$pinned" @state needs_you
tmux set -p -t "$pinned" @state_since "$((LAYOUT_NOW-7500))"
tmux set -p -t "$pinned" @attention_since "$((LAYOUT_NOW-7500))"
tmux set -p -t "$pinned" @worked 183600
. "$B/lib.sh"
ensure_agent_ids "$tmp/queue"
closed=a000000abcdef
record_set "$closed" name "claude-$project-closed-tail"
record_set "$closed" kind claude
record_set "$closed" id fixture-session
record_set "$closed" dir "$tmp/$project"
record_set "$closed" parent "$(pane_agent_id "$parent")"
record_set "$closed" closed "$((LAYOUT_NOW-46800))"
record_set "$closed" worked 4800
record_set "$closed" last_turn 600
record_set "$closed" turns 8
record_set "$closed" started "$((LAYOUT_NOW-259200))"
# Capture the exact production fzf matching/preview flags.
"$B/tmux-agents" </dev/null
FZF_PROMPT='agents · all windows> ' TMUX_AGENTS_LIST_FIELDS=1 COLUMNS=80 "$B/tmux-agents" --list </dev/null >"$tmp/narrow"
FZF_PROMPT='agents · all windows> ' TMUX_AGENTS_LIST_FIELDS=1 COLUMNS=240 "$B/tmux-agents" --list </dev/null >"$tmp/wide"
FZF_PROMPT='agents · all windows> ' TMUX_AGENTS_LIST_FIELDS=1 TMUX_AGENTS_SELECT_FILE="$tmp/selection" TMUX_AGENTS_SELECT="$full" "$B/tmux-agents" --initial-list </dev/null >"$tmp/initial"
python3 - "$tmp" "$real_fzf" "$parent" "$child" "$pinned" "$closed" "$full" "$project" <<'PY'
import os, pathlib, re, shlex, subprocess, sys, unicodedata
root, fzf, parent, child, pinned, closed, full, project = sys.argv[1:]
root = pathlib.Path(root)
ansi = re.compile(r'\x1b\[[0-9;]*m')
failures = []
def check(label, condition, detail=''):
    print(('ok    ' if condition else 'FAIL  ') + label + ((' : '+str(detail)) if not condition else ''))
    if not condition: failures.append(label)
def width(text):
    return sum(0 if unicodedata.combining(c) or unicodedata.category(c) in ('Mn','Me','Cf') else
               2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in text)
def cells(text, start, end):
    result=''; at=0
    for c in text:
        n=width(c)
        if at >= start and at+n <= end: result += c
        at += n
    return result
args=root.joinpath('args').read_bytes().decode().rstrip('\0').split('\0')
check('picker hides horizontal overflow', '--no-hscroll' in args)
flags=[a for a in args if a in ('--read0','--ansi','--no-sort','--no-hscroll') or a.startswith(('--delimiter=','--with-nth=','--nth='))]
# Follow the exact production --with-nth transform, including hidden identity
# fields used by --select and preview but excluded from query matching.
def rendered(record):
    fields=record.split('\x1f')
    spec=next((a.split('=',1)[1] for a in args if a.startswith('--with-nth=')), '2..')
    indexes=[]
    for span in spec.split(','):
        if '..' in span:
            lo,hi=span.split('..')
            indexes.extend(range(int(lo or 1)-1, int(hi) if hi else len(fields)))
        else: indexes.append(int(span)-1)
    return ansi.sub('', ''.join(fields[i] for i in indexes if i < len(fields)))
def parse(filename):
    raw=root.joinpath(filename).read_bytes().decode().split('\0')
    header=rendered(raw[0]); status=width(header[:header.index('STATUS')]); name=width(header[:header.index('NAME')])
    check(filename+': NAME fixed at 26 cells plus two-cell gutter',status-name == 28,(name,status,header))
    result={}
    for record in raw[1:]:
        if not record: continue
        ident=record.split('\x1f')[0].strip()
        lines=rendered(record).splitlines()
        lines=[s for s in lines if not s.startswith('▸ ')]
        if len(lines)<2:
            check(filename+': two-line row '+ident,False,lines); continue
        result[ident]=lines
        # A status glyph begins at the same display cell even after wide text.
        match=re.search(r'[⠿○◆⚠✉✓↺✗] ',lines[0])
        check(filename+': aligned status '+ident, bool(match) and width(lines[0][:match.start()])==status,lines[0])
        match=re.search(r'\d+[smhd](?: · worked \S+)?',lines[1])
        check(filename+': second-row status starts in STATUS '+ident,bool(match) and width(lines[1][:match.start()])==status,lines[1])
        if ident==child:
            activity=cells(lines[1],0,status).rstrip()
            check(filename+': wide activity cut before status',activity.endswith('…') and 'tail-must-be-cut' not in lines[1],lines[1])
            check(filename+': combining text preserved', 'ééé' in activity,activity)
    return result,status
narrow,status=parse('narrow'); wide,wide_status=parse('wide')
check('popup width never changes NAME or STATUS start',status==wide_status)
if child in narrow:
    line=narrow[child][0]
    label=cells(line,0,26).rstrip()
    check('grouped long name keeps kind and tail with middle ellipsis',label.startswith('codex·') and label.endswith('tail') and '…' in label,label)
    check('same-project parent is local',line.rstrip().endswith('claude·secondary'),line)
    check('active interval contributes to two-unit worked time','45s · worked 1h5m' in narrow[child][1],narrow[child][1])
if parent in narrow:
    check('group-local short name is readable',narrow[parent][0].startswith('claude·secondary'),narrow[parent][0])
    check('unknown legacy work omitted','4m' in narrow[parent][1] and 'worked' not in narrow[parent][1],narrow[parent][1])
if pinned in narrow:
    label=cells(narrow[pinned][0],0,26).rstrip()
    check('pinned name keeps full project prefix before compaction',label.startswith('codex-proj') and '·' not in label,label)
    check('coarse hours and two-unit days','2h · worked 2d3h' in narrow[pinned][1],narrow[pinned][1])
if 'closed:'+closed in narrow:
    check('closed age and accumulated work','13h · worked 1h20m' in narrow['closed:'+closed][1],narrow['closed:'+closed][1])
if fzf:
    data=b'\0'.join(root.joinpath('narrow').read_bytes().split(b'\0')[1:])
    def matches(query):
        # fzf's --no-sort filter fast path returns transformed text. Sorting
        # preserves original IDs; --print0 preserves multi-line record boundaries.
        p=subprocess.run([fzf,*flags,'--sort','--print0','--filter='+query],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        check('native fzf accepts query '+query,p.returncode in (0,1),p.stderr.decode())
        return {r.split(b'\x1f')[0].decode().strip() for r in p.stdout.split(b'\0') if r}
    for query, ident in (('claude·secondary',parent),(project,parent),
                         ('claude project secondary',parent),('secondary project claude',parent),
                         ('project secondary claude',parent),('codex tail',child)):
        check('visible name/project terms match: '+query,ident in matches(query))
    for query in ('claude-'+project+'-secondary', full, 'extremely-long-middle-part'):
        check('hidden full-name text does not match: '+query,not matches(query))
    # Search scope stays name + project, excluding status, parent and activity.
    for query in ('working','汉字宽度','started','worked'):
        check('non-search field excluded: '+query,not matches(query))
else:
    print('SKIP native fzf search (fzf unavailable)')
# Initial selection still accepts the original full label, independently of
# the shorter text that the user can query.
initial=root.joinpath('initial').read_bytes().decode().split('\0')
selected=root.joinpath('selection').read_text().strip()
expected=next((i for i,r in enumerate(initial[1:],1) if r.split('\x1f')[0].strip()==child),None)
check('full-name initial selection targets original agent',expected is not None and selected==str(expected),(selected,expected))
preview = next((a.split('=',1)[1] for a in args if a.startswith('--preview=')),None)
if preview is None and '--preview' in args: preview=args[args.index('--preview')+1]
check('production picker supplies preview',bool(preview))
if preview:
    for ident,fullname,unknown in ((child,full,False),(parent,'claude-'+project+'-secondary',True),('closed:'+closed,'claude-'+project+'-closed-tail',False)):
        command=preview.replace('{1}',shlex.quote(ident))
        p=subprocess.run(['/bin/sh','-c',command],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        text=ansi.sub('',p.stdout.decode()); lower=text.lower()
        check('preview full name '+ident,p.returncode==0 and fullname in text,text)
        for field in ('started','age','worked','last','turn'):
            check('preview '+field+' '+ident,field in lower,text)
        if unknown: check('legacy preview started unknown',bool(re.search(r'started\s*[:=]?\s*\?',lower)),text)
        if ident==child:
            check('preview reports three completed turns',bool(re.search(r'(?:turns\s*[:=]?\s*3|3\s+turns)',lower)),text)
            check('preview reports last seven-minute turn','7m' in lower,text)
# Exercise real preview commands at narrow widths, including multiline input
# that resembles the list protocol. The full activity must survive wrapping.
activity='汉字宽度 éé review=value '+('界'*12)+' tail-complete'
subprocess.run(['tmux','set','-p','-t',child,'@activity',activity+'\nP\tsecond-line'],check=True)
record=pathlib.Path(os.environ['XDG_STATE_HOME'])/'tmux-agents'/pathlib.Path(os.environ['TMUX'].split(',')[0]).name/'sessions'/closed
with record.open('a') as out: out.write('activity='+activity+'\n')
def preview_at(ident, columns):
    env=dict(os.environ)
    if columns is None: env.pop('FZF_PREVIEW_COLUMNS',None)
    else: env['FZF_PREVIEW_COLUMNS']=str(columns)
    result=subprocess.run(['/bin/sh','-c',preview.replace('{1}',shlex.quote(ident))],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,check=True)
    return result.stdout.decode(),ansi.sub('',result.stdout.decode()).splitlines()
for ident in (child,'closed:'+closed):
    for columns in (9,24,40):
        raw,lines=preview_at(ident,columns)
        end=next(i for i,line in enumerate(lines) if line.startswith('started '))
        wrapped=lines[1:end]
        expected=activity+('P second-line' if ident==child else '')
        check('preview pads/caps activity to three lines '+ident+str(columns),len(wrapped)==3,wrapped)
        visible=''.join(wrapped)
        check('preview preserves text or marks truncation '+ident+str(columns),visible.rstrip()==expected or (visible.endswith('…') and expected.startswith(visible[:-1])),wrapped)
        check('activity respects CJK display width '+ident+str(columns),all(width(line)<=columns for line in wrapped),wrapped)
        check('separator spans preview width '+ident+str(columns),'─'*columns in lines,lines)
        check('separator is dim '+ident+str(columns),'\x1b[2m'+'─'*columns+'\x1b[0m' in raw)
record.write_text(''.join(line for line in record.read_text().splitlines(True) if not line.startswith('activity=')))
_,lines=preview_at('closed:'+closed,None)
check('legacy closed preview skips missing activity',lines[1:4]==['','',''] and lines[4].startswith('started '),lines)
check('separator defaults to forty cells',lines[6]=='─'*40,lines)
check('production preview pins seven lines while following','--preview-window=right,55%,follow,~7' in args,args)
check('legacy row omits unknown time marker','?' not in narrow[parent][1],narrow[parent][1])
if failures:
    print(str(len(failures))+' checks failed'); sys.exit(1)
print('all passed')
PY

# Membership and timing append distinct protocol fields. Render the owner name
# before adding "member of ", so the prefix cannot break local-name compaction.
# Restore a normal list activity after the multiline preview-protocol fixture.
tmux set -p -t "$child" @activity member-layout-fixture
tmux set -p -t "$child" @member 1
owner_full="claude-$project-extremely-long-secondary-owner-tail"
tmux set -p -t "$parent" @agent "$owner_full"
record_set "$closed" member 1
FZF_PROMPT='agents · all windows> ' TMUX_AGENTS_LIST_FIELDS=1 "$B/tmux-agents" --list >"$tmp/members-sub"
FZF_PROMPT='all · all windows> ' TMUX_AGENTS_LIST_FIELDS=1 "$B/tmux-agents" --list >"$tmp/members-all"
python3 - "$tmp" "$child" "$closed" "$owner_full" "$project" <<'PYMEMBER'
import pathlib,re,sys
root,child,closed,owner,project=sys.argv[1:]
root=pathlib.Path(root)
def rows(file):
    result={}
    for record in root.joinpath(file).read_text().split('\0')[1:]:
        if not record: continue
        fields=record.split('\x1f')
        text=re.sub(r'\x1b\[[0-9;]*m','',''.join(fields[2:]))
        result[fields[0].strip()]=[line for line in text.splitlines() if not line.startswith('▸ ')]
    return result
def compact(label): return label if len(label)<=26 else label[:11]+'…'+label[-14:]
sub,allrows=rows('members-sub'),rows('members-all')
assert child not in sub and child in allrows,(sub,allrows)
localowner=owner.replace('claude-'+project+'-','claude·',1)
assert allrows[child][0].endswith('member of '+compact(localowner)),allrows[child]
assert '45s · worked 1h5m' in allrows[child][1],allrows[child]
for data in (sub,allrows):
    row=data['closed:'+closed]
    assert row[0].endswith('member of '+compact(owner)),row
    assert '13h · worked 1h20m' in row[1],row
print('ok member visibility, compacted owner labels and independent live/saved timing fields')
PYMEMBER
