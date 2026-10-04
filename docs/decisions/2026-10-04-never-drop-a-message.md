# tmux-ask never drops a message

**Context.** A message queued while the user was typing or scrolling in the receiver's pane was given up after `TMUX_ASK_QUEUE_SECS` (30 minutes): it became an `.undelivered` file with a 10-second toast that was easy to miss, the sender believed it was delivered, and nothing retried it.

**Decision.** Every message ends delivered or bounced back to its sender. While the receiver's pane is alive, the deliverer never gives up; it keeps polling. After `TMUX_ASK_QUEUE_SECS` it escalates instead: it sets `@msg_waiting_since` on the receiver's pane, and the agent list and the chip show "✉ message waiting" there (pinned at the top of the list, like needs-you), so the user sees something is blocked on them. Delivery clears it. The copy-mode idle exit (`TMUX_ASK_COPY_IDLE_SECS`) stays as it is.
