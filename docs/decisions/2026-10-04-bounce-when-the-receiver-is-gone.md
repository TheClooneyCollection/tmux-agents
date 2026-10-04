# A message whose receiver is gone goes back to its sender

**Decision.** If the receiver's pane is gone while a message waits, the message is kept as `.undelivered` and the sender gets a notice from `tmux-ask` (`[notice from tmux-ask to <sender> ...]`): "your <request|reply> to X wasn't delivered: X is gone. The text is kept at <path>." so it can resend, reroute or tell the user. If the sender is gone too, every client gets a status-line message saying where the file is, as before.

**Why.** The sender is the one who can act on it, and it thought the message had arrived.
