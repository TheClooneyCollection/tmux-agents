# Messages for a closed sub agent are delivered when it's reopened

**Decision.** When the receiver that's gone is a sub agent that can be reopened (it has a session record with an id), the bounce notice still goes out at once, and says the message is kept and will be delivered if X is reopened, so the sender needn't resend it. `tmux-spawn --resume X` then delivers X's undelivered messages, oldest first, right after it reopens (via `tmux-ask --retry --to X`).

**Why.** Bouncing at once keeps the sender informed; holding the message spares it a resend when the user brings the agent back. If the sender resends anyway, the agent may get it twice, which is safer than never.

**Rejected.** Waiting silently for a reopen: the sender would believe it was delivered, the original problem.
