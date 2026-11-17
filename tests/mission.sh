#!/usr/bin/env bash
# Mission CRUD, literal records, project scope, validation and lock exclusion.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-mission.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
mkdir -p "$tmp/project/sub" "$tmp/stubs"
# These commands must never run during filesystem-only mission operations.
for name in tmux codex claude; do
  cat > "$tmp/stubs/$name" <<'STUB'
#!/bin/sh
printf 'unexpected process: %s %s\n' "$0" "$*" >> "$MISSION_CALLS"
exit 1
STUB
  chmod +x "$tmp/stubs/$name"
done
export PATH="$tmp/stubs:$PATH" MISSION_CALLS="$tmp/calls"
cat > "$tmp/stubs/date" <<'STUB'
#!/bin/sh
printf '%s\n' "$MISSION_NOW"
STUB
chmod +x "$tmp/stubs/date"
export MISSION_NOW=100
git init -q "$tmp/project"
git -C "$tmp/project" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -q --allow-empty -m initial
git -C "$tmp/project" worktree add -q -b linked "$tmp/linked"
cd "$tmp/project/sub"
mission() { "$here/bin/tmux-agents" mission "$@" --from tester; }
fail=0
check() { local label="$1"; shift; if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
# Called through check.
# shellcheck disable=SC2329
reject() {
  if mission "$@" > "$tmp/out" 2> "$tmp/err"; then return 1; fi
  [ ! -s "$tmp/out" ] && [ "$(wc -l < "$tmp/err" | tr -d ' ')" = 1 ]
}
check 'first ID' test "$(mission add 'Build mission')" = M1
dir="$XDG_STATE_HOME/tmux-agents/missions/project"
check 'default owner' grep -qx owner=tester "$dir/M1.mission"
check 'default status' grep -qx status=design "$dir/M1.mission"
check 'same creation/update time' test "$(sed -n 's/created=//p' "$dir/M1.mission")" = "$(sed -n 's/updated=//p' "$dir/M1.mission")"
check 'next ID with options' test "$(mission add Other --owner alice --status active --branch feat/x --worktree ../x)" = M2
check 'one owner field' test "$(grep -c '^owner=' "$dir/M2.mission")" = 1
printf 'future=keep=literal\\value\n' >> "$dir/M1.mission"
export MISSION_NOW=200
mission set M1 --title 'New=title\literal' --owner bob --status plan-ready --branch feat/mission --worktree '../space dir'
check 'set bumps updated' grep -qx updated=200 "$dir/M1.mission"
check 'set preserves created' grep -qx created=100 "$dir/M1.mission"
check 'unknown key survives' grep -Fqx 'future=keep=literal\value' "$dir/M1.mission"
check 'literal title survives' grep -Fqx 'title=New=title\literal' "$dir/M1.mission"
check 'status transition recorded with author' grep -q $'\ttester\tprogress\tstatus: design -> plan-ready$' "$dir/M1.log"
mission set M1 --status plan-ready
check 'same status produces no log' test "$(wc -l < "$dir/M1.log" | tr -d ' ')" = 1
export MISSION_NOW=300
mission log M1 'Decision\literal' --kind decision
mission log M1 'handoff text' --kind handoff
mission log M1 'done text' --kind 'done'
mission log M1 'progress text'
check 'log bumps updated' grep -qx updated=300 "$dir/M1.mission"
check 'default show includes five entries' test "$(mission show M1 | grep -c $'\t')" = 5
check 'default progress kind' grep -q $'\ttester\tprogress\tprogress text$' "$dir/M1.log"
mission show M1 --log 1 > "$tmp/show"
check 'show fields' grep -qx owner=bob "$tmp/show"
check 'show latest log' grep -q 'progress text$' "$tmp/show"
check 'show omits older logs' test "$(grep -c 'handoff text' "$tmp/show" || true)" = 0
mission show M1 --log 0 > "$tmp/show"
check 'zero logs' test "$(grep -c $'\t' "$tmp/show" || true)" = 0
mission set M2 --status 'done'
check 'list hides done' test "$(mission list | wc -l | tr -d ' ')" = 1
check 'all includes done' test "$(mission list --all | wc -l | tr -d ' ')" = 2
mission list --tsv > "$tmp/list"
check 'tsv field order' grep -Fq $'M1\tplan-ready\tbob\tNew=title\\literal\tfeat/mission\t../space dir\t' "$tmp/list"
for status in design plan-ready active needs-decision ready-to-push 'done'; do mission set M1 --status "$status"; done
check 'invalid status' reject set M1 --status nope
check 'invalid kind' reject log M1 text --kind nope
check 'unknown ID' reject show M99
check 'invalid ID path' reject set ../M1 --title oops
check 'tab rejected' reject add $'bad\ttitle'
check 'LF rejected' reject log M1 $'bad\ntext'
check 'CR rejected' reject set M1 --owner $'bad\rname'
check 'author validated' reject list --from $'bad\nauthor'
check 'missing option value' reject set M1 --title
check 'unknown flag' reject list --oops
check 'negative log count' reject show M1 --log -1
check 'extra argument' reject list extra
mkdir "$dir/.lock"
check 'stale lock refuses add' reject add Locked
check 'lock refuses set' reject set M1 --title Locked
check 'lock refuses log' reject log M1 Locked
check 'foreign lock retained' test -d "$dir/.lock"
rmdir "$dir/.lock"
check 'allocation continues after lock released' test "$(mission add Third)" = M3
mv "$dir/M3.mission" "$dir/M9.mission"
check 'allocation uses max existing filename' test "$(mission add Tenth)" = M10
check 'writer releases lock' test ! -d "$dir/.lock"
check 'numeric list order' test "$(mission list --all --tsv | cut -f1 | tr '\n' ' ')" = 'M1 M2 M3 M10 '
# A surviving log must not attach to a newly allocated mission.
printf 'old log\n' > "$dir/M12.log"
check 'orphan log reserves ID' test "$(mission add AfterOrphan)" = M13
cd "$tmp/linked"
mission log M1 'from linked worktree'
check 'linked worktree shares main record' grep -q 'from linked worktree$' "$dir/M1.log"
check 'linked worktree shares allocation' test "$(mission add Shared)" = M14
check 'no worktree project created' test ! -e "$XDG_STATE_HOME/tmux-agents/missions/linked"
cd "$tmp/project/sub"
check 'empty title rejected' reject add ''
check 'empty replacement title rejected' reject set M1 --title ''
check 'empty owner rejected' reject add EmptyOwner --owner ''
check 'empty replacement owner rejected' reject set M1 --owner ''
check 'empty log rejected' reject log M1 ''
check 'bare set rejected' reject set M1
check 'operation help' mission add --help
check 'option-like title' test "$("$here/bin/tmux-agents" mission add --from tester -- --title)" = M15
check 'option-like title preserved' grep -qx title=--title "$dir/M15.mission"
# Publish failure must not append either an explicit or implicit status log.
cat > "$tmp/stubs/mv" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$tmp/stubs/mv"
cp "$dir/M1.log" "$tmp/log-before"
cp "$dir/M1.mission" "$tmp/record-before"
check 'failed log publication rejected' reject log M1 'must not appear'
check 'failed log leaves log unchanged' cmp -s "$dir/M1.log" "$tmp/log-before"
check 'failed set publication rejected' reject set M1 --status active
check 'failed set leaves log unchanged' cmp -s "$dir/M1.log" "$tmp/log-before"
check 'failed publication leaves record unchanged' cmp -s "$dir/M1.mission" "$tmp/record-before"
rm "$tmp/stubs/mv"
# Deterministic contention: release the holder only when the writer polls.
export MISSION_LOCK="$dir/.lock" MISSION_POLLS="$tmp/polls"
cat > "$tmp/stubs/sleep" <<'STUB'
#!/bin/sh
printf 'poll\n' >> "$MISSION_POLLS"
rmdir "$MISSION_LOCK"
STUB
chmod +x "$tmp/stubs/sleep"
mkdir "$dir/.lock"
check 'writer retries then acquires released lock' test "$(mission add Contended)" = M16
check 'contention reached retry boundary' test -s "$MISSION_POLLS"
check 'retried writer releases lock' test ! -d "$dir/.lock"
rm "$tmp/stubs/sleep"
check 'no real agent or tmux invocation'  test ! -e "$MISSION_CALLS"
[ ! -f "$MISSION_CALLS" ] || cat "$MISSION_CALLS"
exit "$fail"
