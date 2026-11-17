#!/usr/bin/env bash
# CI reports all workflows, bounded failure tails, pending and watch outcomes.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-ci.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
git -C "$tmp/project" init -q
git -C "$tmp/project" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit -qm initial --allow-empty
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'run list') [ "${CI_OFFLINE:-0}" = 0 ] || exit 1; cat "$CI_FIXTURE/runs" ;;
  'run watch') printf '%s\n' "$3" >> "$CI_FIXTURE/watched" ;;
  'run view')
    if [ "$4" = --log-failed ]; then
      for ((i=1;i<=50;i++)); do echo "failed job line $i"; done
    else cat "$CI_FIXTURE/result"; fi ;;
  *) echo 'unexpected gh invocation' >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" CI_FIXTURE="$tmp"
cd "$tmp/project"
run() { "$here/bin/tmux-agents" ci "$@"; }
printf '1\tcompleted\tsuccess\tLinux\n2\tcompleted\tskipped\tMac\n' > "$tmp/runs"
run > "$tmp/out"
grep -qx 'CI passed' "$tmp/out"
printf '1\tcompleted\tfailure\tLinux\n2\tin_progress\t\tMac\n' > "$tmp/runs"
if run > "$tmp/out"; then exit 1; else [ "$?" = 1 ]; fi
grep -qx 'CI failed' "$tmp/out"
grep -qx 'failed job line 50' "$tmp/out"
[ "$(wc -l < "$tmp/out")" -le 20 ]
printf '2\tin_progress\t\tMac\n' > "$tmp/runs"
if run > "$tmp/out"; then exit 1; else [ "$?" = 2 ]; fi
grep -qx 'CI pending' "$tmp/out"
printf 'completed\tsuccess\n' > "$tmp/result"
run --watch HEAD > "$tmp/out"
grep -qx 2 "$tmp/watched"
grep -qx 'CI passed' "$tmp/out"
printf 'completed\tcancelled\n' > "$tmp/result"
if run --watch > "$tmp/out"; then exit 1; else [ "$?" = 1 ]; fi
: > "$tmp/runs"
if run > "$tmp/out"; then exit 1; else [ "$?" = 2 ]; fi
if CI_OFFLINE=1 run > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'cannot list CI runs' "$tmp/err"
if run missing-ref > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
if run --unknown > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
echo 'ok CI success, failure, pending, watch, empty and offline'
