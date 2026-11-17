#!/usr/bin/env bash
# Composite writes persist before notification; failure cannot undo mission work.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-mission-composite.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
cp "$here/bin/tmux-agents-mission" "$here/bin/lib.sh" "$here/bin/turn-state.sh" "$tmp/bin/"
cat > "$tmp/bin/tmux-ask" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ ! -d "$MISSION_DIR/.lock" ] || exit 9
printf '%s\n' "$@" > "$MISSION_NOTICE"
[ "${MISSION_FAIL:-0}" = 0 ]
STUB
chmod +x "$tmp/bin/tmux-ask"
export XDG_STATE_HOME="$tmp/state" MISSION_DIR="$tmp/state/tmux-agents/missions/project" MISSION_NOTICE="$tmp/notice"
cd "$tmp/project"
run() { "$tmp/bin/tmux-agents-mission" "$@" --from owner; }
[ "$(run add Example)" = M1 ]
run set M1 --status active --notify main
printf '%s\n' --from owner --note main 'M1 status: design -> active' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/notice"
run set M1 --status plan-ready --notify main --notice
grep -qx -- --notice "$tmp/notice"
run 'done' M1 'report path' --notify main
grep -qx status=done "$MISSION_DIR/M1.mission"
grep -q $'\towner\tdone\treport path$' "$MISSION_DIR/M1.log"
grep -qx 'M1 done: report path' "$tmp/notice"
if MISSION_FAIL=1 run set M1 --status active --notify missing > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'mission saved, but notification' "$tmp/err"
grep -qx status=active "$MISSION_DIR/M1.mission"
cp "$MISSION_DIR/M1.mission" "$tmp/before"
if run set M1 --owner other --notify main > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
cmp "$MISSION_DIR/M1.mission" "$tmp/before"
if run 'done' M1 '' > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run set M1 --status active --notice > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run 'done' M99 missing > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
[ ! -d "$MISSION_DIR/.lock" ]
cp "$MISSION_DIR/M1.mission" "$tmp/before"
cp "$tmp/notice" "$tmp/notice-before"
for target in --any --notice -peer; do
  if run set M1 --status 'done' --notify "$target" > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
  grep -q 'not an option' "$tmp/err"
  cmp "$MISSION_DIR/M1.mission" "$tmp/before"
  cmp "$tmp/notice" "$tmp/notice-before"
done
echo 'ok composite mission status, done, notification and partial failure'
