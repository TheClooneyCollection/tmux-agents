# Shared EXIT cleanup for suites that use a private tmux socket.
# Source this file; call cleanup_test_server before removing temporary state.
cleanup_test_server() {
  local sock="${1-${sock:-}}"
  local queue_root queue_path pid pids attempt
  case "${sock:-}" in
    ''|.|..|default|*/*) echo "ABORT: unsafe cleanup socket '${sock:-}'" >&2; return 1 ;;
  esac
  queue_root="/tmp/tmux-agents-$(id -u)/queue"
  queue_path="$queue_root/$sock"

  # --kick/--deliver started directly by a suite are our children. Reap them
  # before closing the server, so they cannot launch another delivery job.
  pids="$(jobs -pr)"
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  tmux -L "$sock" kill-server 2>/dev/null || true

  # tmux run-shell workers can outlive kill-server. Their --deliver argument
  # contains the exact private queue path; never match names or global queues.
  # Stop them before rm: delivery/bounce cleanup can otherwise recreate it.
  for attempt in {1..100}; do
    pids="$(ps -axo pid=,command= | awk -v q="$queue_path/" '
      /[t]mux-ask.*--deliver/ && index($0, q) {print $1}')" || return
    [ -n "$pids" ] || break
    for pid in $pids; do
      if [ "$attempt" -lt 80 ]; then
        kill "$pid" 2>/dev/null || true
      else
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
    sleep .05
  done
  if [ -n "$pids" ]; then
    echo "ABORT: delivery workers still using $queue_path" >&2
    return 1
  fi
  rm -rf "$queue_path"
}
