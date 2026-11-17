#!/usr/bin/env bash
# Trusted panes infer the mission author; explicit authors remain filesystem-only.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-mission-from.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
cat > "$tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-sessions) exit 0 ;;
  list-panes) printf '%%0\n' ;;
  display-message) printf 'trusted-worker\n' ;;
  *) echo "unexpected tmux call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/tmux"
export PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" TMUX="$tmp/test,1,0" TMUX_PANE=%0
unset CLAUDECODE TMUX_AGENTS_PINNED
cd "$tmp/project"
run() { "$here/bin/tmux-agents" mission "$@"; }
if run add Refused > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'pass --from' "$tmp/err"
[ "$(TMUX_AGENTS_PINNED=1 run add Trusted)" = M1 ]
[ "$(CLAUDECODE=1 run add Claude)" = M2 ]
run show M1 --from explicit > "$tmp/out"
grep -qx owner=trusted-worker "$tmp/out"
[ "$(run add Explicit --from named)" = M3 ]
run show M3 --from explicit > "$tmp/out"
grep -qx owner=named "$tmp/out"
echo 'ok inferred pinned Codex and Claude authors; untrusted refusal and explicit compatibility'
