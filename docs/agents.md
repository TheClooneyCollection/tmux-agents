# Agent support

Claude, Codex and configured Codex profiles have full integration today, with the existing adapter-specific differences such as Codex having no turn-start hook. Other agents have limited support: tmux can launch and manage their panes and transport messages, but successful autonomous work depends on the application accepting those messages and following the protocol.

## Choosing an agent

`tmux-agents start AGENT`, `tmux-spawn [AGENT]`, chain role settings and `tmux-agents chain-config` accept `claude`, `codex`, configured Codex profiles and executable basenames on PATH. A configured profile takes precedence over a same-named executable. Supply a command name, not a path or a shell command string. `start chain` retains its special meaning as the chain launcher.

For `tmux-spawn`, put the agent selector before options. A leading single word is validated as an agent selector; use the existing options-first task form for a bare task instead. `tmux-agents start AGENT -- ...` passes explicit agent arguments through unchanged. Other executables receive no injected initial prompt and no Claude/Codex flags. Validation by `chain-config` does not run the executable, and its role/value/source output is unchanged.

## Capabilities

| Capability | Claude/Codex and configured profiles | Other executables |
| --- | --- | --- |
| Start, hidden helpers, visible splits, membership and ownership/depth rules | Supported | Supported |
| Names, connect, peers, peek and explicit dismissal | Supported | Supported by exact name or pane ID |
| Type and `kind@window` connection shortcuts | Claude/Codex | Not supported |
| Requests, replies, notices, queue and retry | Integrated workflow | Transport only; application acceptance and protocol compliance are not guaranteed |
| Explicit sender identity with `--from NAME` | Supported | Supported |
| Automatic identity pinning | Existing adapter behavior | Not guaranteed |
| Initial spawn task or new-chain main prompt | Delivered by the launcher | Not sent; send the actual brief manually when ready |
| Automatic turn state, worked time and permission/needs-you detection | Existing hooks and reports | Not available; shown untracked with `-` and no worked time |
| Auto permission flags and scoped permission setup | Existing adapters and `sub_auto` | Not added; the application's own permissions apply |
| Conversation resume through `tmux-spawn` | Supported for resumable saved sub agents | Not supported |
| Installed skills and agent-chain integration | Supported | Not provided |

An executable on PATH is not necessarily an interactive coding agent. It must accept terminal input and have a way to run `tmux-ask` to participate in agent conversations. Message transport uses paste followed by Enter; this may not submit a prompt in every TUI. A successful send means tmux accepted the transport operation, not that the application accepted or executed the task.

## Sending the first task

For an unknown executable, a task supplied to `tmux-spawn` is **not sent**. The existing spawn result explains the manual step. Keep the task text: once the new agent is visibly at its input prompt, the sender must resend the actual brief with `tmux-ask`, using the full assigned name. There is no automatic first-task delivery when the prompt appears.

For example, replace `my-agent`, `ME` and `PEER` with the executable, sender name and full name printed by spawn:

```sh
tmux-spawn my-agent --from ME --name review
```

Inspect its pane or preview to confirm the input prompt is ready. Then send the work:

```sh
message_dir="${TMPDIR:-/tmp}/tmux-agents/$ME"
mkdir -p "$message_dir"
brief_file="$(mktemp "$message_dir/brief.XXXXXX")"
# write the review brief to "$brief_file"; remove after a successful send
tmux-ask --from ME PEER --message-file "$brief_file"
```

Put the concrete goal, paths and constraints in the file. `--message-file` reads a literal message from one readable regular file up to 1 MiB; symlinks are rejected, positional text cannot be combined with it, and stdin is ignored. Create each message file with `mktemp` under `${TMPDIR:-/tmp}/tmux-agents/$ME/` so agents sharing a working directory cannot overwrite one another or dirty the project; remove it after a successful send or keep the unique file for a retry. Do not assume that the agent can load the tmux-agents or agent-chain skill. The message envelope supplies the sender, receiver and reply command; the agent still needs shell access and permission to execute that command. Use explicit `--from` for its replies and later commands because generic identity pinning is not guaranteed.

Normal queue rules still apply after you send: `queued` means the message is retained, so do not send it again. That differs from a spawn task reported as not sent. Use `tmux-ask --pending` to inspect undelivered messages. Closing an unsupported conversation does not make it resumable; a new launch is a new conversation.

## Chains and waiting

Other executables may be selected for main, secondary or worker. A new chain with an unknown main receives **no initial chain prompt**; send the actual chain brief manually once that main is at its prompt. There is no agent-chain skill integration for these tools, and naming an executable does not teach it how to coordinate the chain. Main and secondary are particularly risky choices because delegation and coordination depend on that protocol. Supervise them; a known Claude/Codex coordinator with a manually instructed worker is easier to operate.

For an unknown secondary, the main must send the role and actual goal manually after the prompt is ready. With `--for`, the owner receives the introduction brief as usual and must send the worker its actual task when ready. Do not tell unknown agents to load an unavailable skill.

Waiting logic is unchanged: a live untracked child can leave a tracked parent working indefinitely. The status chip cannot prove that the unknown agent finished or needs permission. Inspect its pane and explicitly dismiss it when its work is complete. No new automatic completion or parent-wait behavior is implied by accepting its executable name.

## Contributing full support

PRs adding full support for more agents are welcome. A full integration should document and test:

- Launch arguments, initial prompt handling and readiness behavior.
- Turn and permission hooks, or equivalent lifecycle events, including worked-time accounting.
- Safe identity pinning for the agent's tool processes.
- Conversation IDs, saved records and resume behavior.
- Scoped permission rules without broad bypasses.
- Skill installation or equivalent protocol integration, including chain roles.
- Message transport, queue/retry behavior and isolated stub regression tests, plus a real-client smoke-test report recording the tested version.

Publish adapter-specific limitations rather than assuming every client behaves like Claude or Codex. See [Configuration](configuration.md) for existing settings and the [guide](guide.md) for the shared commands.
