# Read all session records once. Metadata comes from one batched stat call.
BEGIN {
    FS = "="
    n = split(ENVIRON["LIST_MTIMES"], lines, "\n")
    for (i = 1; i <= n; i++) {
        tab = index(lines[i], "\t")
        if (tab) mtime[substr(lines[i], tab + 1)] = substr(lines[i], 1, tab - 1)
    }
}
FNR == 1 { files[FILENAME] = 1 }
{ key = $1; sub(/^[^=]*=/, ""); value[FILENAME, key] = $0 }
END {
    for (file in files) {
        at = value[file, "closed"]
        if (at == "") at = mtime[file]
        aid = file; sub(/^.*\//, "", aid)
        if (now - at > keep) { print "X\t" file; continue }
        # Keep id-less records in the graph: their descendants may be reopenable.
        printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", aid, value[file,"id"], at, value[file,"parent"], value[file,"dir"], value[file,"name"], value[file,"parent_name"]
    }
    # Empty records can still expire, but never have a reopenable id.
    for (file in mtime)
        if (!(file in files) && now - mtime[file] > keep) print "X\t" file
}
