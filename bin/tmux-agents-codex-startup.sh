#!/usr/bin/env bash
# Internal, read-only startup observer for spawned Codex and its profiles.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
pane="$1" identity="$2" launcher="$3"
seen=0 announced=0 remaining=120
# Identity is checked again under the accounting lock before any mutation.
# shellcheck disable=SC2329
finish() {
  [ "$seen" = 1 ] || return 0
  [ "$(pane_agent_id "$pane")" = "$identity" ] || return 0
  _agent_work "$pane" startup-perm "" "" "$identity" 2>/dev/null || true
}
trap finish EXIT
trap 'exit 0' TERM INT HUP
while kill -0 "$launcher" 2>/dev/null; do
  snapshot="$(tmux display-message -p -t "$pane" '#{@agent_id}|#{pane_dead}|#{@tracked}|#{pane_in_mode}' 2>/dev/null)" || exit 0
  IFS='|' read -r current dead tracked in_mode <<< "$snapshot"
  [ "$current" = "$identity" ] && [ "$dead" = 0 ] && [ "$tracked" = 1 ] || exit 0
  if [ "$in_mode" != 1 ]; then
    # Check the cursor row, including dim placeholders, not quoted transcripts.
    if chain_prompt_input "$pane" "$identity" ›; then exit 0; fi
    screen="$(tmux capture-pane -p -J -t "$pane" 2>/dev/null)" || exit 0
    if [[ "$screen" = *'Folder access'* && "$screen" = *'Trust this folder?'* &&
          "$screen" = *'1. Trust and continue'* && "$screen" = *'2. Back to Agent Command Center'* ]]; then
      if [ "$seen" = 0 ]; then
        _agent_work "$pane" startup-perm on "" "$identity"
        seen=1
        if [ "$announced" = 0 ] && [ "$(pane_agent_id "$pane")" = "$identity" ]; then
          announced=1
          # The record exists before the child runs; @parent is attached by
          # the spawning caller afterwards and can still be empty here.
          parent_id="$(record_get "$identity" parent)"
          parent=""
          [ -z "$parent_id" ] || parent="$(find_pane_by_id "$parent_id")"
          if [ -n "$parent" ]; then
            "$here/tmux-ask" --system-notice "$parent" \
              "$(record_get "$identity" name) is waiting for folder trust confirmation. The task has not started. Ask the user to open its pane and choose; do not approve trust automatically." tmux-agents \
              </dev/null >/dev/null 2>&1 &
          fi
        fi
      fi
    else
      if [ "$seen" = 1 ]; then finish; seen=0; fi
    fi
  fi
  # Bound unknown startup screens; a detected trust dialog stays visible until
  # resolved, the pane exits, or its stable identity changes.
  if [ "$seen" = 0 ]; then
    remaining=$((remaining - 1))
    [ "$remaining" -gt 0 ] || exit 0
  fi
  sleep 1
done
