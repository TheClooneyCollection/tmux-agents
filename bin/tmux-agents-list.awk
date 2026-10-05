# One pane snapshot and one record batch; all graph walks stay in memory.
BEGIN { FS = "\t"; OFS = "\t"; prefix = ENVIRON["LIST_PREFIX"] "-"; now = ENVIRON["LIST_NOW"] + 0 }
$1 == "P" {
    p = $2
    if (p in name) next
    order[++np] = p
    name[p]=$3; dead[p]=$4; perm[p]=$5; state[p]=$6; parent[p]=$7
    session[p]=$8; activity[p]=$9; path[p]=$10; location[p]=$11
    attention[p]=$12; waiting[p]=$13; window[p]=$14
    if ($15 != "-") byid[$15]=p
    next
}
$1 == "R" { record[$2]=1; rid[$2]=$3; closed[$2]=$4; owner[$2]=$5; dir[$2]=$6; label[$2]=$7; parentlabel[$2]=$8; next }
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
function add(rank, section, id, label, status, ownername, report) {
    nr++; ranks[nr]=rank; sections[nr]=section; ids[nr]=id; labels[nr]=label
    statuses[nr]=status; parents[nr]=ownername; reports[nr]=report
    # Labels are validated ASCII; every status starts with one single-column glyph.
    sub(/^[^ ]+/, "", status); widths[nr]=1+length(status)
    if (length(label)>namewidth) namewidth=length(label)
    if (widths[nr]>statuswidth) statuswidth=widths[nr]
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
    target=ENVIRON["LIST_WINDOW"]
    if (target=="") target=window[ENVIRON["TMUX_PANE"]]
    scope=ENVIRON["LIST_SCOPE"]; mode=ENVIRON["LIST_MODE"]
    namewidth=4; statuswidth=6
    for (p in name) if (window[p]==target && target!="") member[p]=1
    do {
        changed=0
        for (p in name) if (!member[p] && member[parent[p]]) { member[p]=1; changed=1 }
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
        } else if (scope!="all" && !member[p]) continue
        ownername=(parent[p] in name) && name[parent[p]]!="-" ? name[parent[p]] : "-"
        add(rank,section,p,name[p]=="-" ? p : name[p],status,ownername,report)
        rowprojects[nr]=rowproject
    }
    # Shell glob order used to be the stable tie-break for closed records.
    for (n in record) if (rid[n]!="" && !(n in byid) && (scope=="all" || (target!="" && record_window(owner[n])==target))) {
        j=++nc
        while (j>1 && "x" names[j-1]>"x" n) { names[j]=names[j-1]; j-- }
        names[j]=n
    }
    for (i=1;i<=nc;i++) {
        n=names[i]; age=now-closed[n]
        if (age<3600) age=int(age/60) "m"
        else if (age<86400) age=int(age/3600) "h"
        else age=int(age/86400) "d"
        add(20000000000-closed[n],"closed (" nc ") · enter reopens","closed:" n,label[n],"↺ closed",owner_label(n),project[dir[n]] " · closed " age " ago")
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
        if (fields) {
            # fzf strips these control separators when drawing, but uses them
            # to match only name/project. The original ID stays field 1.
            printf "%s \037",ids[r]
            if (section!=last) { printf "\033[1;38;5;180m▸ %s\033[0m\n",section; last=section }
            printf "\037%-*s\037  %s%*s  %s\n  \033[38;5;245m",namewidth,labels[r],color(statuses[r]),statuswidth-widths[r],"",parents[r]
            projectname=rowprojects[r]
            pos=index(report,projectname " · ")
            if (section=="needs you" || ids[r] ~ /^closed:/) {
                printf "%s\037%s\037%s",substr(report,1,pos-1),projectname,substr(report,pos+length(projectname))
            } else printf "\037%s\037 · %s",projectname,report
            printf "\033[0m%c",30
            continue
        }
        printf "%s ",ids[r]
        if (section!=last) { printf "\033[1;38;5;180m▸ %s\033[0m\n",section; last=section }
        printf "%-*s  %s%*s  %s\n  \033[38;5;245m%s\033[0m%c",namewidth,labels[r],color(statuses[r]),statuswidth-widths[r],"",parents[r],report,30
    }
}
