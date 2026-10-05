# One pane snapshot and one record batch; all graph walks stay in memory.
BEGIN { FS = "\t"; OFS = "\t"; prefix = ENVIRON["LIST_PREFIX"] "-"; now = ENVIRON["LIST_NOW"] + 0; for (i=1;i<256;i++) byte[sprintf("%c",i)]=i }
# Preview activity is the final field and can contain tabs or multiple lines.
# Handle the whole preview stream before interpreting list protocol tags.
ENVIRON["LIST_PREVIEW"]=="1" {
    if (NR==1) {
        preview_name=$2; preview_start=$3; work=$4; preview_last=$5; preview_turns=$6
        if (numeric(work) && numeric($7) && $8=="working" && $9=="" && $10=="" && $11!=1) work+=now>$7 ? now-$7 : 0
        preview_activity=$12
        for (i=13;i<=NF;i++) preview_activity=preview_activity " " $i
    } else preview_activity=preview_activity "\n" $0
    next
}
$1 == "P" {
    p = $2
    if (p in name) next
    order[++np] = p
    name[p]=$3; dead[p]=$4; perm[p]=$5; state[p]=$6; parent[p]=$7
    session[p]=$8; activity[p]=$9; path[p]=$10; location[p]=$11
    attention[p]=$12; waiting[p]=$13; window[p]=$14; ismember[p]=($22==1)
    if ($15 != "-") byid[$15]=p
    state_since[p]=$16; worked[p]=$17; last_turn[p]=$18; turns[p]=$19; turn_start[p]=$20; started[p]=$21
    next
}
$1 == "R" { record[$2]=1; rid[$2]=$3; closed[$2]=$4; owner[$2]=$5; dir[$2]=$6; label[$2]=$7; parentlabel[$2]=$8; saved_since[$2]=$9; saved_worked[$2]=$10; saved_last[$2]=$11; saved_turns[$2]=$12; saved_start[$2]=$14; recordmember[$2]=($15==1); next }
$1 == "D" { project[$2]=$3; next }
# Walk to the first visible live ancestor, with the original pane as fallback.
function visible(p, original, visited) {
    original=p
    while ((p in name) && !index(visited, "|" p "|")) {
        visited=visited "|" p "|"
        if (index(session[p], prefix) != 1) return p
        p=parent[p]
    }
    return original
}
function record_window(n, visited) {
    while (n != "" && !index(visited, "|" n "|")) {
        visited=visited "|" n "|"
        if (n in byid) return window[visible(byid[n])]
        n=owner[n]
    }
    return ""
}
function owner_label(n, p) {
    p=owner[n]
    if (p in byid) return name[byid[p]]
    if (label[p]!="") return label[p]
    return parentlabel[n]!="" ? parentlabel[n] : "-"
}
# Decode UTF-8 explicitly under LC_ALL=C, so BSD awk and byte-oriented awk
# agree. Combining marks occupy no cells; East Asian wide/emoji occupy two.
function charwidth(cp) {
    if (cp<32 || (cp>=127 && cp<160) || (cp>=768 && cp<=879) ||
        (cp>=6832 && cp<=6911) || (cp>=7616 && cp<=7679) ||
        (cp>=8203 && cp<=8207) || (cp>=8234 && cp<=8238) ||
        (cp>=8294 && cp<=8297) || (cp>=8400 && cp<=8447) ||
        (cp>=65024 && cp<=65039) || (cp>=65056 && cp<=65071) ||
        (cp>=917760 && cp<=917999)) return 0
    return (cp>=4352 && (cp<=4447 || cp==8986 || cp==8987 || cp==9001 || cp==9002 ||
        (cp>=9193 && cp<=9196) || cp==9200 || cp==9203 ||
        (cp>=9725 && cp<=9726) || (cp>=9748 && cp<=9749) ||
        (cp>=9800 && cp<=9811) || cp==9855 || cp==9875 || cp==9889 ||
        (cp>=9898 && cp<=9899) || (cp>=9917 && cp<=9918) ||
        (cp>=9924 && cp<=9925) || cp==9934 || cp==9940 || cp==9962 ||
        (cp>=9970 && cp<=9971) || cp==9973 || cp==9978 || cp==9981 ||
        cp==9989 || (cp>=9994 && cp<=9995) || cp==10024 || cp==10060 ||
        cp==10062 || (cp>=10067 && cp<=10069) || cp==10071 ||
        (cp>=10133 && cp<=10135) || cp==10160 || cp==10175 ||
        (cp>=11035 && cp<=11036) || cp==11088 || cp==11093 ||
        (cp>=11904 && cp<=42191 && cp!=12351) ||
        (cp>=44032 && cp<=55203) || (cp>=63744 && cp<=64255) ||
        (cp>=65040 && cp<=65049) || (cp>=65072 && cp<=65135) ||
        (cp>=65281 && cp<=65376) || (cp>=65504 && cp<=65510) ||
        (cp>=127744 && cp<=129791) || (cp>=131072 && cp<=262141))) ? 2 : 1
}
function decode(s, at, b, cp, j) {
    b=byte[substr(s,at,1)]; bytes=1; cp=b
    if (b>=240) { bytes=4; cp=b-240 }
    else if (b>=224) { bytes=3; cp=b-224 }
    else if (b>=192) { bytes=2; cp=b-192 }
    for (j=1;j<bytes;j++) cp=cp*64+byte[substr(s,at+j,1)]-128
    return charwidth(cp)
}
function cells(s, at, total) {
    for (at=1;at<=length(s);at+=bytes) total+=decode(s,at)
    return total+0
}
function head(s, limit, at, used, w, out) {
    for (at=1;at<=length(s);at+=bytes) {
        w=decode(s,at); if (used+w>limit) break
        out=out substr(s,at,bytes); used+=w
    }
    return out
}
function tail(s, limit, at, total, skip, w, out) {
    total=cells(s); skip=total-limit
    for (at=1;at<=length(s);at+=bytes) {
        w=decode(s,at)
        if (skip<=0) out=out substr(s,at,bytes)
        skip-=w
    }
    return out
}
function fit(s, limit) { return cells(s)<=limit ? s : head(s,limit-1) "…" }
function compact(s) { return cells(s)<=26 ? s : head(s,11) "…" tail(s,14) }
function padded(s, width) { return s sprintf("%*s",width-cells(s),"") }
function localname(s, proj, kind, prefix) {
    kind=s; sub(/-.*/,"",kind); prefix=kind "-" proj "-"
    return index(s,prefix)==1 ? kind "·" substr(s,length(prefix)+1) : s
}
function numeric(n) { return n ~ /^[0-9]+$/ }
function elapsed(n) {
    if (n<0) n=0
    return n<60 ? int(n) "s" : (n<3600 ? int(n/60) "m" : (n<86400 ? int(n/3600) "h" : int(n/86400) "d"))
}
function duration(n, a, b) {
    if (n<0) n=0
    if (n<60) return int(n) "s"
    if (n<3600) return int(n/60) "m"
    if (n<86400) { a=int(n/3600) "h"; b=int(n%3600/60); return a (b ? b "m" : "") }
    a=int(n/86400) "d"; b=int(n%86400/3600); return a (b ? b "h" : "")
}
function timecell(since, work) {
    return (numeric(since) ? elapsed(now-since) : "?") (numeric(work) ? " · worked " duration(work) : "")
}
function wrapped(s, width, at, used, w, ch, out) {
    gsub(/\r/, "", s); gsub(/\t/, " ", s)
    for (at=1;at<=length(s);at+=bytes) {
        w=decode(s,at); ch=substr(s,at,bytes)
        if (ch=="\n") { out=out ch; used=0; continue }
        if (used+w>width && used>0) { out=out "\n"; used=0 }
        out=out ch; used+=w
    }
    return out
}
function metadata(full, start, work, last, count) {
    return full (preview_activity!="" ? "\n" wrapped(preview_activity,preview_width) : "") "\nstarted " (numeric(start) ? start : "?") " · age " (numeric(start) ? elapsed(now-start) : "?") "\nworked " (numeric(work) ? duration(work) : "?") " · last turn " (numeric(last) ? duration(last) : "?") " · turns " (numeric(count) ? count : "?")
}
function add(rank, section, id, label, status, ownername, report, timing) {
    nr++; ranks[nr]=rank; sections[nr]=section; ids[nr]=id; labels[nr]=label
    statuses[nr]=status; parents[nr]=ownername; reports[nr]=report
    timings[nr]=timing
    widths[nr]=cells(status)
    if (widths[nr]>statuswidth) statuswidth=widths[nr]
    if (cells(timing)>statuswidth) statuswidth=cells(timing)
    if (!(section in best) || rank<best[section]) best[section]=rank
}
function before(a,b) {
    if (best[sections[a]] != best[sections[b]]) return best[sections[a]] < best[sections[b]]
    if (sections[a] != sections[b]) return "x" sections[a] < "x" sections[b]
    if (ranks[a] != ranks[b]) return ranks[a] < ranks[b]
    # Preserve snapshot order (and alphabetical record order) for equal ranks.
    return a < b
}
function color(s) {
    if (s=="⚠ permission") return "\033[1;97;41m" s "\033[0m"
    if (s=="◆ needs you" || s=="✉ message waiting") return "\033[1;30;48;5;214m" s "\033[0m"
    if (s=="⠿ working") return "\033[38;5;117m" s "\033[0m"
    if (s=="○ idle" || s=="↺ closed") return "\033[38;5;244m" s "\033[0m"
    if (s=="✓ done") return "\033[38;5;114m" s "\033[0m"
    return "\033[38;5;240m" s "\033[0m"
}
END {
    if (ENVIRON["LIST_PREVIEW"]=="1") {
        preview_width=ENVIRON["FZF_PREVIEW_COLUMNS"]
        if (!numeric(preview_width) || preview_width<2) preview_width=40
        print metadata(preview_name,preview_start,work,preview_last,preview_turns)
        printf "\033[2m"
        for (i=0;i<preview_width;i++) printf "─"
        printf "\033[0m\n"
        exit
    }
    target=ENVIRON["LIST_WINDOW"]
    if (target=="") target=window[ENVIRON["TMUX_PANE"]]
    scope=ENVIRON["LIST_SCOPE"]; mode=ENVIRON["LIST_MODE"]
    namewidth=26; statuswidth=6
    for (p in name) if (window[p]==target && target!="") inwindow[p]=1
    do {
        changed=0
        for (p in name) if (!inwindow[p] && inwindow[parent[p]]) { inwindow[p]=1; changed=1 }
    } while (changed)
    for (i=1;i<=np;i++) {
        p=order[i]
        if (!((name[p]!="-" && (mode=="all" || parent[p]!="-")) || waiting[p]!="-")) continue
        if (dead[p]==1) { rank=5; status="✗ exited" }
        else if (perm[p]!="-") { rank=0; status="⚠ permission" }
        else if (waiting[p]!="-") { rank=1; status="✉ message waiting" }
        else if (state[p]=="needs_you") { rank=1; status="◆ needs you" }
        else if (state[p]=="idle") { rank=3; status="○ idle" }
        else if (state[p]=="done") { rank=4; status="✓ done" }
        else { rank=2; status="⠿ working" }
        section=index(session[p],prefix)==1 ? substr(session[p],length(prefix)+1) : project[path[p]]
        rowproject=section
        report=activity[p]
        if (dead[p]!=1 && (waiting[p]!="-" || (parent[p]!="-" && (perm[p]!="-" || state[p]=="needs_you")))) {
            since=perm[p]!="-" ? perm[p] : (waiting[p]!="-" ? waiting[p] : attention[p])
            if (since !~ /^[0-9]+$/) since=now
            rank=since-20000000000
            if (report=="-") report="no report yet"
            report=location[visible(p)] " · " section " · " report
            section="needs you"
        } else {
            if (mode!="all" && ismember[p]) continue
            if (scope!="all" && !inwindow[p]) continue
        }
        ownername=(parent[p] in name) && name[parent[p]]!="-" ? name[parent[p]] : "-"
        work=worked[p]
        if (numeric(work) && numeric(turn_start[p]) && state[p]=="working" && perm[p]=="-" && waiting[p]=="-" && dead[p]!=1)
            work+=now>turn_start[p] ? now-turn_start[p] : 0
        since=state_since[p]
        if (perm[p]!="-") since=perm[p]
        else if (waiting[p]!="-") since=waiting[p]
        else if (state[p]=="needs_you" && !numeric(since)) since=attention[p]
        add(rank,section,p,name[p]=="-" ? p : name[p],status,ownername,report,timecell(since,work))
        pp=parent[p]
        parentprojects[nr]=index(session[pp],prefix)==1 ? substr(session[pp],length(prefix)+1) : project[path[pp]]
        rowmembers[nr]=ismember[p]
        rowprojects[nr]=rowproject
    }
    # Shell glob order used to be the stable tie-break for closed records.
    for (n in record) if (rid[n]!="" && !(n in byid) && (scope=="all" || (target!="" && record_window(owner[n])==target))) {
        j=++nc
        while (j>1 && "x" names[j-1]>"x" n) { names[j]=names[j-1]; j-- }
        names[j]=n
    }
    for (i=1;i<=nc;i++) {
        n=names[i]
        add(20000000000-closed[n],"closed (" nc ") · enter reopens","closed:" n,label[n],"↺ closed",owner_label(n),project[dir[n]],timecell(closed[n],saved_worked[n]))
        rowmembers[nr]=recordmember[n]
        rowprojects[nr]=project[dir[n]]
    }
    # Small in-memory stable sort replaces sort/cut/column processes.
    for (i=1;i<=nr;i++) {
        j=i
        while(j>1 && before(i,sorted[j-1])) { sorted[j]=sorted[j-1]; j-- }
        sorted[j]=i
    }
    fields=ENVIRON["TMUX_AGENTS_LIST_FIELDS"]=="1"
    if (fields) printf "ID\037\037"; else printf "ID "
    printf "%-*s  %-*s  PARENT%s%c",namewidth,"NAME",statuswidth,"STATUS",(nr==0 && scope!="all" ? " (ctrl-t: all windows)" : ""),30
    for (i=1;i<=nr;i++) {
        r=sorted[i]; section=sections[r]; report=reports[r]
        if (report=="" || report=="-") report="no report yet"
        display=labels[r]; ownerdisplay=parents[r]
        if (section==rowprojects[r]) {
            display=localname(display,rowprojects[r])
            if (parentprojects[r]==rowprojects[r]) ownerdisplay=localname(ownerdisplay,rowprojects[r])
        }
        display=compact(display); ownerdisplay=(rowmembers[r] ? "member of " : "") compact(ownerdisplay)
        if (fields) printf "%s \037%s\037",ids[r],labels[r]
        else printf "%s ",ids[r]
        if (section!=last) { printf "\033[1;38;5;180m▸ %s\033[0m\n",section; last=section }
        if (fields) printf "\037"
        printf "%s",padded(display,namewidth)
        if (fields) printf "\037"
        printf "  %s%*s  %s\n  \033[38;5;245m%s  %s  ",color(statuses[r]),statuswidth-widths[r],"",ownerdisplay,padded(fit(report,namewidth-2),namewidth-2),padded(timings[r],statuswidth)
        if (fields) printf "\037"
        printf "%s",rowprojects[r]
        if (fields) printf "\037"
        printf "\033[0m"
        printf "%c",30
    }
}
