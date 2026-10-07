# Top-level agents go idle at turn end

**Context.** Top-level agents now receive turn hooks through `tmux-agents start`. Finishing a response with nothing pending marked them `needs_you`, although they were simply waiting for the user's next prompt.

**Decision.** At turn end, a working agent without `@parent` goes idle when it has no unfinished live children, live awaited replies, explicit wait or Claude background commands. Clear `@attention_since` and complete its worked-time turn through the normal idle transition. Pending work still keeps it working with `waiting for ...`. Sub agents and members retain needs-you behavior because they have a parent. Existing done and idle states retain their precedence.

**Why.** Waiting for the next user prompt is normal for a top-level agent. Needs-you attention identifies a sub agent or member that ended its turn without replying or waiting on work.

**Rejected.** Marking every tracked agent needs-you at turn end, or forcing top-level agents idle while delegated or background work is still pending.
