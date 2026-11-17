# Streamlining routine agent commands

Research only; no code changed. Goal: every routine tmux-agents flow is one command, with no identity hunting and no temp-file ceremony.

## What already exists (do not rebuild)

- `tmux-peers` with no `--from` already prints `you: NAME (%pane)`. It is the "whoami". Main ran three failing guesses (`tmux-whoami`, `tmux-agents whoami`, `tmux show-options`) because the skill never says "`tmux-peers` is whoami" in the orient path (skills/tmux-agents/SKILL.md:19 says it, but agent-chain's rejoin text says "then use `tmux-peers --from <me>`", which presumes the name is known).
- `--from` is already optional where `$TMUX_PANE` is trusted: `lib.sh` `self_pane` uses `$TMUX_PANE`, and `trusted_pane` is true for Claude (`CLAUDECODE`) and pinned Codex (`TMUX_AGENTS_PINNED`). Only unpinned Codex needs it. The skill nevertheless says "pass `--from` to every call". Exception: `tmux-agents mission` hard-requires it (`bin/tmux-agents-mission`: `[ -n "$from" ] || die`), and `open` requires it.
- Inline messages already work: `tmux-ask` and `tmux-spawn` take message text as arguments or stdin (`tmux-ask --help`, `tmux-spawn --help`). The skill still pushes `mkdir` + `mktemp` + write + send + `rm` for every brief and report.
- `tmux-spawn --role R --name N`: `--name` overrides the role's default name (`SKILL.md` agent-chain), so the post-spawn `tmux-rename` main did for a wf2 name is avoidable today.
- `mission add` already takes `--owner`; `mission list --tsv`, `show --log N` exist. `tmux-dismiss --done` batches cleanup. `tmux-ask --reply` without a name does not exist, but the receiver already stores the latest requester (used for stop notes).
- `tmux-notes` unread summary is already injected into Claude's prompt by hook, so Claude rarely needs `tmux-notes` to learn there is something; only to read it.
- Not present: any combined status/resume command, `@role` pane option (role is inferred from the name suffix), `tmux-spawn --mission/--open`, mission-aware `--note` without `fleet-command`, composite mission verbs.

## Current flows and command counts

Counts are tool calls (each is one API round trip on the agent's whole context).

| Flow | Sequence today | Calls |
| --- | --- | --- |
| Orient after clear (observed) | whoami guesses x3, `tmux-peers`, `mission list`, `ls HANDOFF.md && git check-ignore`, `cat HANDOFF.md`, `mission show M5`, `tmux-notes` | 9 (documented minimum 5-6) |
| Spawn a role for a mission | mkdir+mktemp, write brief, `tmux-spawn --role`, `mission set --owner`, `tmux-agents open` (designer), optional `tmux-rename`, `rm` brief | 6-8 |
| Send long message or notice | mkdir+mktemp, write file, `tmux-ask --message-file`, `rm` | 4 (1 if short) |
| Reply with long report | same as above with `--reply` | 4 |
| Progress to a peer plus mission | `tmux-ask --note`, `mission log` | 2 |
| Mission status change plus tell main | `mission set --status`, `mission log`, `tmux-ask --notice` | 3 |
| Report status (sub agent) | `tmux-agent-report` (+ `mission log` when in a mission) | 1-2 |
| Check on a slow peer | `tmux-peers`, `tmux-peek`, sometimes `board` | 2-3 |
| Open an agent for the user | `tmux-peers` (name), `tmux-agents open NAME --from ME` | 1-2 |
| Rename | `tmux-rename` | 1 |
| Land and complete (main side) | wait for reply, `mission set done`/`log done` (interface), `tmux-dismiss` interface, `tmux-dismiss` designer | 3-4 |
| Start chain (main) | `tmux-rename ME main`, `mission add` per mission | 2+ |
| CI watch handoff | brief files (3), `tmux-spawn --role runner`, runner runs `gh run watch`, reply (4) | 7+ |
| Read a reply / full body | arrives as a prompt; `tmux-read ID` only when needed | 0-1 |

Every row also carries a hidden cost: the agent must know its own name for `--from`, which is where most orient failures come from.

## Proposals, ranked by savings

Savings = calls removed per occurrence x how often it happens.

### 1. `tmux-agents status` (orient and check, 9 to 1)

One read-only command, safe to run at the start of any turn:

```
tmux-agents status [--notes] [--handoff] [--missions full] [PEER]
```

Prints, in order, only non-empty sections:

1. `you: NAME (%pane) role=main parent=- depth=0 kind=claude` (role from new `@role`, falling back to the name suffix).
2. Peers table (same as `tmux-peers`) with a STATE column: working/idle/done, since, `waiting on`.
3. Open missions for this project (`mission list`), and for each mission I own: last 3 log lines (replaces `mission show --log 3`).
4. Unread notes: count and sender list; `--notes` prints and marks them read (replaces `tmux-notes`).
5. Undelivered queued messages (`tmux-ask --pending` summary line).
6. `HANDOFF.md`: `none`, `present, untracked, ignored (N lines)`, or `WARNING: tracked`; `--handoff` prints it. Path is the project root, found like `mission_directory` does (git common dir parent).

`status PEER` shows that agent's state line plus the last 5 screen lines (replaces `peers` + `peek` for "is it stuck"). `resume` is an alias so "cleared, resume" maps to one obvious word.

Implementation: a thin bash script `bin/tmux-agents-status` dispatched from `bin/tmux-agents` (add to the `case` at the top) that reuses `get_peers`, `pane_name`, `mission` listing and `_notes_store count`; the state column comes from the same snapshot `tmux-agents-list.awk` uses. Also make unknown subcommands suggest `status` (the `whoami` failure). Add it to the Codex rules prefix list.

### 2. Infer `--from` and add `@role` (removes name hunting from every flow)

- Make `--from` optional everywhere for trusted panes. `mission` and `open` should call `self_pane` like the other tools instead of requiring the flag. Unpinned Codex keeps `--from`.
- `tmux-peers --me` prints just the name (script-friendly), for the rare "name only" need.
- Set `@role` in `tmux-spawn --role R` and in `tmux-agents start chain` (main). This removes the `tmux-rename ME main` step in "Starting the chain" and makes `status` reliable instead of parsing suffixes.
- Skill: replace "pass `--from` to every call" with "omit `--from` unless you are unpinned Codex; first run `tmux-agents status`".

### 3. No temp files for briefs and reports (4 to 1)

Mostly skill text, since stdin already works:

- Claude: `tmux-ask PEER <<'MSG' ... MSG` and `tmux-spawn --role R <<'MSG' ... MSG`; delete the mkdir/mktemp/rm recipe.
- New `--message-file -` reads stdin as the retained attachment when a positional summary is given: `tmux-ask --note PEER --message-file - "summary" <<'MSG' ...full report... MSG`. Today stdin is ignored in that mode, hence the temp file for every report over ten lines.
- New `--rm` with `--message-file PATH` deletes the file after a successful send (Codex, where heredocs are discouraged: write the file with the patch tool, then one send call). Optional `tmux-agents scratch` prints a fresh unique path under `${TMPDIR:-/tmp}/tmux-agents/$ME/` (creates the dir), replacing mkdir+mktemp.

### 4. `tmux-spawn --mission ID --open` (6-8 to 1)

- `--mission ID`: set the new agent as the mission's owner and log `spawned NAME (role)`; validates the ID first.
- `--open`: run the `tmux-agents open` logic for the user after spawn (designer case).
- With `--role` + `--name` + stdin brief, the full designer launch is one call:
  `tmux-spawn --role designer --name wf2-researcher-streamline --mission M5 --open <<'MSG' ... MSG`.

### 5. Composite mission verbs (2-3 to 1)

- `tmux-ask --note ... --mission ID` should always append to the local mission log (kind progress); `fleet-command` stays a best-effort extra. Today local logging needs a second command.
- `mission set ID --status S [--notify PEER] [--notice]`: after the change, send one note (or notice) to PEER with the new status; default text `ID status: old -> new`.
- `mission done ID "report path or summary" [--notify NAME]`: status `done` + `log --kind done` + note, in one call. Dismissal stays separate on purpose (main dismisses only after the reply; keep that guard).
- `tmux-agent-report --mission ID "text"` also writes the mission log line.

### 6. `tmux-ask --reply` with no name (and clearer defaults)

Reply to the remembered latest requester; the request footer would read `tmux-ask --reply <<'MSG'`. Saves no calls, but removes copy errors and tokens from every reply. Keep the named form for multiple requesters.

### 7. `tmux-agents ci` (optional, 7 to 2)

`tmux-agents ci [--watch] [REF]`: wraps `gh run list --commit` and `gh run watch`, prints pass/fail and the failing job's log tail in at most 20 lines. Main or interface hands a runner the one-line brief "run `tmux-agents ci --watch` and reply", or the interface runs it directly. Repo/GitHub specific, so rank last and confirm demand.

## Migration

Everything is additive; no flag is removed or renamed.

1. Ship in this order: 2 (infer `--from`, `@role`) and 1 (`status`) together, then 3, 4, 5, 6, 7. Each is independently releasable.
2. Old forms (`--from`, `--message-file` + summary, separate `mission set owner`) keep working, so existing agents and mid-flight chains are unaffected; skill text moves first, code is ahead of it, so installed copies need the release before the skill tells agents to use a new flag.
3. Codex rules (`.codex/rules` via `install.sh`): allow the `tmux-agents status` and `tmux-agents ci` prefixes.
4. Record the decision in `docs/decisions/` (new file, e.g. `2026-11-17-streamlined-commands.md`) and mention the new commands in `docs/guide.md`.
5. Tests: status output sections (with stubs, no real agents), `--from` omission for `mission`/`open`, `spawn --mission` ownership, `--message-file -`, `--rm`.

## Skill text changes

- `skills/tmux-agents/SKILL.md`: identity section (lines ~16-24): say to run `tmux-agents status` first and to omit `--from` unless unpinned Codex. Replace the `mktemp` recipes (sub agents, `--for`, report and reply rules, command list lines 52-62) with heredoc/stdin forms plus the Codex `--rm` form. "Sending a request" step 1 (`tmux-peers`) becomes `tmux-agents status`. Add `status PEER` to "slow reply" step 5.
- `skills/agent-chain/SKILL.md`: "Starting the chain" step 1 loses the rename. "Spawn by consumer" line uses stdin and `--mission --open`. "Missions" documents the composite verbs. "Rejoining after a restart or clear" becomes: run `tmux-agents status --handoff`, then act; it replaces the peers/mission list/HANDOFF/notes sequence and the `tmux-peers --from <me>` presumption. "Messages and checks" drops the mktemp paragraph for `--message-file -`.
- `docs/guide.md` (rejoin section, line ~266) and `docs/agents.md` (sending the first task): same replacements.
- The `missions`, `wrap-up` and `afk` skills (outside this repo) reference `--from` and HANDOFF; update after release through the usual skills repo flow.

## Savings summary

| Rank | Change | Calls saved per use | Frequency |
| --- | --- | --- | --- |
| 1 | `tmux-agents status` | about 8 | every clear/resume, many turn starts |
| 2 | Infer `--from`, `@role`, `--me` | 1-3 (name discovery, rename, errors) | every command |
| 3 | Stdin/`--message-file -`/`--rm` | 3 | every brief, report, notice |
| 4 | `spawn --mission --open` | 5-7 | every mission role spawn |
| 5 | Composite mission verbs | 1-2 | every status change |
| 6 | Nameless `--reply` | 0 (fewer errors) | every request |
| 7 | `tmux-agents ci` | about 5 | every landing |

Open question for main: whether `status` should also read the `HANDOFF.md` body by default (saves one more call after a clear, but costs tokens when the handoff is long). This plan keeps it behind `--handoff`, with the skill telling main to pass it on resume.

## Role choices: where the configured agent is NOT honored

`chain-config` and `tmux-spawn --role` do resolve the user's per-role agent and args correctly (`bin/lib.sh` `chain_roles_resolve`, `bin/tmux-spawn:280-291`). The leaks are around that path, not in it:

1. **Plain `tmux-spawn` ignores roles.** With no `--role`, the agent defaults to the caller's own kind and profile (`tmux-spawn --help`). An interface that is Claude and spawns a worker plain gets a Claude worker; if it names `codex`, it gets plain `codex`, not the configured `codex-2nd`. The generic "Sub agents" section of skills/tmux-agents/SKILL.md teaches exactly this plain form and never mentions roles, so any agent that loads only that section takes the leak path.
2. **A positional AGENT silently beats the role and drops its args** (`bin/tmux-spawn:288`: role args apply only when the chosen agent equals the role agent). The skill even shows `tmux-spawn codex --role reviewer` as an example. `--role worker` plus `codex` therefore yields plain codex with no `--model`, and nothing says so.
3. **Per-chain overrides cover only three roles.** `start chain --main/--interface/--worker` travel through `TMUX_AGENTS_CHAIN_MAIN/SECONDARY/WORKER` env (`lib.sh:1545-1614`, `tmux-spawn:125`). Designer, reviewer, runner and researcher can only come from tmux options or defaults, and role args have no per-chain path at all.
4. **Instruction-file preferences cannot reach `spawn --role`.** The skill says they are "passed as explicit overrides", but `tmux-spawn` never parses overrides (only `chain-config` does), so the only carrier is a positional AGENT, which is leak 2.
5. **The skill's role table hardcodes defaults** ("worker: codex", "interface: claude / Sonnet"), so agents plan from the table instead of the user's config. Spawned owners also get no role hint: the `--for` notice (`tmux-spawn:692`) says only "tmux-ask ... first task".
6. **Changing a choice needs a tmux.conf edit and source**, and applies only to new chains; there is no way to see or set it from the agent flow.

### Making the role the one obvious path

- **Print the resolution on every spawn**: `spawned NAME role=worker agent=codex-2nd args="--model X" (source: option)`; for a plain spawn inside a chain, `role=none agent=claude (inherited)`. Deviation becomes visible in the single line agents already read. Cheapest, ship first.
- **Warn on plain spawn in a chain**: if the caller has `@role` or chain env and passes no `--role`/AGENT, print to stderr `tmux-spawn: no --role; inheriting <kind>. Use --role ROLE to follow chain-config (or --plain to silence)`. Later an opt-in setting makes it an error.
- **Positional AGENT keeps role semantics**: with `--role R AGENT`, use AGENT but print `role args dropped` explicitly, and let `-- ARGS` re-supply them. Remove `tmux-spawn codex --role reviewer` from the skill's examples; point overrides to `chain-config ROLE --worker X` validation instead.
- **Snapshot all roles per chain**: have `start chain` export one `TMUX_AGENTS_CHAIN_<ROLE>` (and `_ARGS`) for every role, resolved once at launch and forwarded by `tmux-spawn`, so a chain keeps the choices it started with even if the tmux option changes, and every role has `--designer/--reviewer/...` launch flags. Instruction-file preferences then enter once, at the main's launch snapshot or as `tmux-agents chain-config --set` (below), not per call.
- **`tmux-agents chain-config set ROLE AGENT [-- ARGS]`**: sets the tmux option live (`@tmux_agents_chain_<role>`, `_args`), validates it exactly like `--interface/--worker`, and prints the `set -g` line for tmux.conf. Lets a user or the skill change "worker uses codex-2nd" in one call.
- **Put the role table where agents already look**: `tmux-agents status` (proposal 1) prints `roles: worker=codex-2nd (option) reviewer=claude --model fable ...`, and the agent-chain skill's table becomes "see `tmux-agents status`", with a spawn recipe per role (`tmux-spawn --role worker --mission M5 <<'MSG'`). The `--for` owner notice and the interface brief gain `spawn helpers with tmux-spawn --role <role>; never a bare agent name`.
- **Skill text**: in skills/tmux-agents/SKILL.md "Sub agents", lead with `--role` when in a chain and demote bare AGENT to "only when the user asks for a different agent"; in agent-chain, delete the hardcoded agent/model column.

Ranking (add to the savings table): resolution line + plain-spawn warning (no new flags, fixes the observed codex vs codex-2nd miss) goes just above rank 3; all-role snapshot and `chain-config set` sit with rank 5.
