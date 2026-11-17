# v3: backend adapters and a new product name

Research, 2026-11-17. Source baseline: `d069a93`. Proposal only; no implementation or naming decision. v2.0.0 remains tmux-based. External capabilities below were checked against current documentation, not tested locally.

**Recommendation:** separate the agent registry, state machine and delivery queue from the terminal runtime. Keep tmux as the reference adapter; prove the boundary with one second backend before freezing a public adapter protocol. Preserve existing commands through compatibility wrappers. A wrapper around the `tmux` executable alone would preserve its pane-centric assumptions, not provide a portable backend.

## 1. Dependency inventory

This is a source-level inventory grouped by concern, including embedded Perl and generated shell commands. Paths are relative to the repository root; function names identify boundaries more reliably than line numbers.

| Concern | Current dependencies and source locations | Extraction boundary |
| --- | --- | --- |
| Identity | `bin/lib.sh`: `require_tmux`, `self_pane`, `trusted_pane`, naming helpers, `pane_agent_id`, `find_pane_by_id`, ID migration. Uses `TMUX`, `TMUX_PANE`, `%pane`, `pane_pid`, command, cwd, `@agent`, `@agent_id`, `@tracked`, `@shell`. Embedded Perl migration calls tmux directly. `bin/tmux-rename`, `bin/tmux-peers` also access options. | Stable agent ID belongs to core; live endpoint and generation belong to runtime. Names are labels. Existing stable IDs are a good starting point. |
| Addressing and topology | `lib.sh` target resolution, peers/ancestor traversal; `tmux-connect`, `tmux-disconnect`, `tmux-peers`, `tmux-rename`. Numeric/session/window targets, `kind@window`, `list-panes`, `list-windows`, `@parent`, `@peers`, `@closed`, `@peer_names`, `@member`, `@role`. Connect also highlights panes and stores picker scope. | Core owns peer/owner/member graph by stable IDs. Adapter resolves explicitly native targets; core resolves agent names, IDs and project scope. |
| Message transport | `tmux-ask`: named `load-buffer`, bracketed `paste-buffer`, delayed `send-keys Enter`, buffer deletion; `run-shell -b` delivery worker; `pane_in_mode`, `pane_dead`, client activity, client notices and optional copy-mode cancellation. `lib.sh`: `user_busy`/typing checks, queue socket namespace. `tmux-agents-notes-digest.sh` checks pane options; `turn-state.sh` records delivery tokens. | Queue, expiry, FIFO, retry and delivery evidence stay core. Runtime supplies guarded input and activity facts; never equate successful paste with a completed agent turn. |
| Live state and accounting | `lib.sh` accounting and cleanup, `turn-state.sh`, `tmux-agent-report`: pane options for `@state`, `@state_since`, `@activity`, `@started`, `@worked`, `@last_turn`, `@turns`, `@turn_start`, turn bookkeeping, permission/attention/message wait timestamps, `@asking`, `@explicit_needs_you`, `@last_requester`, `@last_delivered`, `@codex_thread`, digest timestamps. Read/modify/write spans shell and Perl plus file locks. | Core owns transactional state transitions and checkpoints. tmux options become a view/cache during migration, with one declared writer. |
| Durable data and configuration | `lib.sh` session records, work/identity/turn locks, shell command records and message queues derive namespaces from the tmux socket basename. `notes-lib.sh`, `tmux-notes`, `tmux-read` store/read notes and archives; fast note count still looks up `@agent_id`. Settings use global `@tmux_agents_*`, `show-options`, legacy `show-environment`; `tmux-agents-chain-config` writes globals. Missions and project config already use files. | Backend instance namespace replaces implicit socket namespace. Preserve ID/conversation distinction, retention, lock ordering and migration journals. Settings become core data with a legacy tmux settings reader. |
| Spawn/start/resume | `tmux-spawn`, `tmux-agents-start`, `lib.sh`: `new-session`, `new-window`, `split-window`, `wait-for` launch gates, shell quoting/env forwarding, pane TTY checks, `default-shell`, `remain-on-exit`, rename options, `@resume_shell`, ownership and tracking. `tmux-agents-codex-startup.sh` reads screen/dead/mode/ID; `tmux-agents-chain-resume.sh` captures screen, sends Escape, `/rc`, task paste and Enter. | Runtime creates or adopts an execution endpoint; core chooses agent command, profile, resume ID and ownership. Readiness recognition and agent-specific input stay separate from terminal implementation. |
| Hide/open/dismiss | `tmux-dismiss`, `tmux-agents-open`, `lib.sh` cleanup: descendant traversal, `kill-pane`, hidden `agents-<project>` sessions, client selection, `switch-client`, popup attachment. `tmux-agents --view` attaches with `-S` after unsetting `TMUX`. | Dismiss policy remains core. Closing a view must not terminate a job. Persistent background execution and interactive attachment are distinct capabilities. |
| Shells/project launchers | `tmux-shell`, `tmux-shell-run`: persistent shell session, creation lock/gate, popup, `@shell_*` status/origin/exit code. `tmux-agents-projects.sh`, `tmux-agents-main-sequence`, `tmux-agents-chain`: named sockets, grouped sessions, attach/switch, indexed windows, move/select-window, `destroy-unattached`, renumbering and rename control. `tmux-shell-history` supplies the history picker. | Core distinguishes shell jobs from agents. Project sequence is an ordered launch model; native window indices/grouped clients are optional presentation. History parsing itself is portable. |
| List, chip, board, status | `tmux-agents`: one bulk pane snapshot, client/window scoping, capture preview, fzf actions, popup navigation, status layout/chip daemon, prefix key validation/bindings and alert messages. `tmux-agents-list.awk` consumes pane-oriented columns, `TMUX_PANE`, and tmux styling; `tmux-agents-records.awk` consumes record data. `tmux-agents-board.pl` invokes tmux itself and duplicates socket-path logic; board wrapper reads prefix options. `tmux-agents-status`, `tmux-peek` use snapshots/capture. | Normalize one snapshot; compute rows/counts in core; render plain/ANSI/tmux styles separately. Keep the one-snapshot/one-record-pass budget. Popups/chip/borders are optional integrations. |
| Runtime hooks and formats | `tmux/tmux-agents.conf`: `pane-died`, `pane-exited`, `after-kill-pane`, `window-unlinked`, `pane-mode-changed`, `alert-bell`; binds `a`, `A`, shell keys; `run-shell`, popup, status interval. `lib.sh` border refresh uses `pane-border-*`; scripts use `#{...}` conditions, client/pane/session/window fields and `#[...]` styles. | Adapter events wake reconciliation/delivery; hooks are hints, reconciled against snapshots after loss/restart. Format expressions stay entirely in tmux integration. |
| Claude/Codex integration | `lib.sh` launch preparation builds Claude notification/tool/prompt/stop hooks with `--pane`; Codex notify uses stable ID, thread binding and message evidence in `tmux-agent-report`. `integrations/sh/codex.sh` and fish wrappers pin `TMUX`, `TMUX_PANE`, identity/profile env into Codex shared execution. `integrations/claude/settings.json` and `integrations/codex/tmux-agents.rules` authorize existing command prefixes. | Agent-driver hooks call a core report API carrying agent ID and launch generation. Backend socket/endpoint pins supplement, never replace, explicit identity. Permission policy remains agent-specific. |
| Installation/tests/docs | `install.sh` links `tmux-*`, installs skills/rules/wrappers and upgrades the selected server. CI/probes/test helpers and many suites construct private tmux servers. Skills, help, README translations and configuration docs describe panes and prefixes. | Keep tmux regression suites; add backend contract suites with fake agents. Installer selects integrations and compatibility commands. `tmux-agents-ci` is an operational helper, not a runtime abstraction. |

The durable pieces are not all portable today: session/queue paths and migrations still encode tmux, and board reads tmux even though mission storage does not. Preserve the existing behavior in [sub-agent state documentation](../design/sub-agents.md) and [list budget](../performance.md).

## 2. Small adapter contract

Use a versioned executable protocol (structured requests/results, e.g. JSON over stdin/stdout), so adapters can be written in any language. Shell helpers can implement the first internal version. No plugin language or daemon requirement needs to be imposed on all backends.

```text
describe() -> {protocol_version, backend, instance_id, capabilities}
snapshot() -> {revision, endpoints[], clients[]}
create(LaunchSpec) -> EndpointRef
adopt(native_target, expected_process?) -> EndpointRef       [optional]
input(ref, InputBatch, guard) -> InputResult
capture(ref, {lines, ansi}) -> CaptureResult                [optional]
terminate(ref, {grace_ms}) -> Result
present(ref, {action: open|hide, client?, placement?}) -> Result [optional]
events(cursor?) -> stream<Event>                            [optional]
```

Semantics:

- `EndpointRef = {instance_id, native_id, generation}`. The core registry binds it to `agent_id`; resume preserves that ID but creates a fresh generation. Backend instance identity must not collide across servers/hosts. Stale references fail, including late hooks and delayed Enter after a restart.
- `LaunchSpec = {agent_id, generation, argv[], cwd, env, terminal_size, placement, anchor?}`. Placement is background by default, or an explicitly requested split/window. Creation registers identity before releasing the child to run; adapter owns the startup gate and rollback. Pass argv as data, not untrusted shell source. Adoption implements current-pane `start`/`--here`; unsupported adoption must fail explicitly.
- `snapshot` returns one bulk view: lifecycle (running/exited), command/cwd, terminal size, optional UI grouping/client focus, input activity/mode and uncertainty. It does not invent agent turn state from terminal activity. No external command per agent or ancestor. Core merges its registry/records once and resolves names in memory.
- `input` serializes a batch for an endpoint: literal bracketed text, submit or a named key. A guard includes expected generation and input-safety requirements. Return `submitted`, `busy`, `gone`, `unsupported`, or `indeterminate`. Busy remains queued by core; uncertain safety must not be treated as idle. Partial paste/submit failure is indeterminate, not permission to blindly replay. Core owns message IDs and queue receipts; terminal input cannot promise exactly-once execution.
- `capture` returns text plus truncation/availability metadata; unsupported capture means an explicit unavailable preview, not fabricated history. Agent drivers own `/rc`, startup/trust-dialog recognition and Enter timing; adapters own terminal encoding and guarded writes.
- `terminate` targets only that generation, including its managed process group where appropriate. Core authorizes ownership and orders subtree termination, saves accounting and retains reopen records. `present(hide)` never kills it; `open` reports no-client/unsupported in headless mode.
- `events` reports endpoint exit, activity/mode changes and view changes. Core can use a bounded reconciliation scheduler when events are absent. Delivery workers/digest timers must survive the sending CLI's exit; currently tmux `run-shell` provides part of this service. An external adapter must supply a durable runtime or use the core supervisor.

Required for a runnable backend: describe, snapshot, create, guarded input, terminate. Capabilities declare background persistence, adoption, split, capture, interactive open/hide and events. A backend lacking interactive viewing can still run agents with a clearly reduced UI. Native target lookup, borders, notifications and status widgets belong to optional UI extensions, not mandatory fake tmux operations.

Backend-independent core: CLI parsing/output contracts; agent IDs/names/ownership/peers; profiles and launch policy; state transitions and worked time; missions/project configuration; notes/archive/read cursors; queued message ordering/retry/expiry; authorization; retention; portable list/board/status models. Use a private core event endpoint or locked file transaction API, with generation validation. Runtime `@state` is not the source of truth in the final design.

Separate **agent drivers** (Claude/Codex launch, resume, hooks, readiness) from **runtime adapters** (tmux/PTY/etc.). This prevents a terminal-independent implementation from accidentally requiring every agent to speak a terminal protocol, or every backend to know Codex internals.

## 3. Candidate backends

Fit/blockers are engineering judgments from the cited interfaces, not conformance claims.

| Backend | Fit | Blockers / first proof |
| --- | --- | --- |
| tmux | Reference; existing hidden execution, attach, capture, input, hooks and options already cover today's workflows. | Extract all direct calls, including Perl/format/popup paths. Avoid slower per-field RPCs. Test unchanged compatibility and generation guards. |
| Zellij | Strong second terminal candidate. Current docs expose pane JSON, targeted input/capture and creation IDs. | Establish minimum supported version, cross-session snapshot cost, background persistence, atomic safe-input behavior and readiness under user typing/scrolling. Popup/chip integration is different and may need a plugin. Do not assume old releases support current CLI flags. See [programmatic control](https://zellij.dev/documentation/programmatic-control.html) and [actions](https://zellij.dev/documentation/cli-actions). |
| WezTerm | CLI lists/manipulates panes, spawns and sends/reads text; its multiplexer provides a path to persistent execution. | Select GUI vs mux domain explicitly. Prove disconnected lifetime, activity/mode visibility and multi-client attach semantics; no direct equivalent of arbitrary pane-option state is needed after core extraction. See [CLI](https://wezterm.org/cli/cli/index.html) and [multiplexing](https://wezterm.org/multiplexing.html). |
| kitty remote control | Can launch, target, send text with bracketed paste, retrieve text and focus windows. | Remote control must be configured; GUI-window lifecycle is not a detached job supervisor. `detach-window` moves windows between UI containers, not persistent headless execution. Treat as a UI-hosted backend or frontend to a PTY supervisor until persistence is proven. See [remote control](https://sw.kovidgoyal.net/kitty/remote-control/). |
| Plain processes + PTY daemon | Most direct terminal-independent interactive runtime. Supervisor owns PTYs, process groups, input serialization, attach and scrollback. | Highest new systems cost: terminal emulation for screen capture, resize, replay/backpressure, crash recovery, client input arbitration, Unix socket permissions and macOS/Linux behavior. Plain pipes alone do not reproduce interactive TUIs. |
| Headless/server | Useful minimum: missions/archive/status without tmux; runnable headless agents via PTY supervisor or agent-specific structured protocols. | Separate read-only control plane from a runtime that actually starts/sends to agents. Need API authentication/authorization for remote use, reconnect/idempotency and structured approval flows. No popup/open parity unless a terminal/web frontend is supplied. |

Suggested proof: tmux plus a fake backend first, then Zellij for real terminal portability. If the user's first priority is running without *any* terminal multiplexer, choose the PTY/server proof instead; budget it as a separate runtime project.

## 4. Commands and compatibility

Use `<product>` below until naming is decided. `fleet ask` illustrates the desired shape but should not be installed unconditionally.

| Existing entry point | Canonical v3 shape |
| --- | --- |
| `tmux-ask`, `tmux-spawn`, `tmux-dismiss`, `tmux-connect`, `tmux-disconnect` | `<product> ask`, `spawn`, `dismiss`, `connect`, `disconnect` |
| `tmux-peers`, `tmux-peek`, `tmux-read`, `tmux-notes`, `tmux-rename`, `tmux-shell` | `<product> peers`, `peek`, `read`, `notes`, `rename`, `shell` |
| `tmux-agent-report` | `<product> report` |
| `tmux-agents` and `start`, `board`, `mission`, `status`, `open`, `chain`, `chain-config`, `main-sequence`, `project-config` subcommands | `<product>` and the same subcommands; preserve current argument order/outputs |

Keep old executable wrappers throughout v3; share one parser/implementation. Resolve backend from explicit selection, pinned caller identity or configuration, not command spelling. Native `%3`/`session:window.pane`, `--client`, and indexed `--target` retain exact meaning on tmux; other backends return a capability error instead of guessing an equivalent. Names/IDs and logical commands stay portable. Preserve tmux's pane-ID stdout for existing chain launch callers; provide structured v3 output for portable endpoint references.

Support old env names/config paths and old message headers while writing a versioned new format. `turn-state.sh` currently recognizes `via tmux-ask` tokens, so changing banners alone breaks stale-notification checks. Update allow rules, hooks, generated resume commands, skills and installer together. Do not emit deprecation warnings on machine stdout. Document aliases as legacy in v3; consider removal only in a later major with explicit approval and usage evidence, not on a preset near-term deadline.

## 5. Names and conflicts

Quick public discovery is not package reservation or trademark clearance. No candidate below is claimed available.

| Candidate | Assessment |
| --- | --- |
| **Agent Fleet**, `agent-fleet` | Clear description and close to the user's idea, but already used by [codemeall/agent-fleet](https://github.com/codemeall/agent-fleet) and [agent-fleet.org](https://agent-fleet.org/docs/ref/releases/summary/). Would need a distinctive qualifier/package namespace. |
| **Fleet**, `fleet` | Short but conflicts directly with [Rancher's Fleet CLI](https://fleet.rancher.io/how-tos-for-users/install-use-fleet-cli) and the user's old CLI alias. Avoid as a default binary; opt-in alias only. |
| **Agent Fleet Command**, `fleet-command` | User's sunset project, already a distinct protocol/package. Reusing it suggests that v3 is its server rather than tmux-agents' successor. Avoid without an explicit consolidation/migration decision. |
| **Agent Harbor**, `agent-harbor` | Attractive runtime-neutral wording, already occupied by an agent tool with an `ah` CLI: [Agent Harbor docs](https://docs.agent-harbor.com/guides/troubleshooting). |
| **Agent Deck**, `agent-deck` | Several existing products; one concrete conflict is [MJUIUC/agent-deck](https://github.com/MJUIUC/agent-deck). Avoid. |
| **Agent Flotilla**, `agent-flotilla` | Close metaphor, but adjacent agent orchestration tools already use Flotilla: [Flotilla deployment docs](https://chipi.github.io/flotilla/architecture/deployment/). Poor distinctiveness even if the exact binary were free. |

Local sunset-project check: `../agent-fleet-command/README.md`, `pyproject.toml` and `docs/technical/transport-interface.md` still describe/export both `fleet-command` and `fleet`; database is `~/.local/state/fleet/fleet.sqlite`, with `FLEET_URL`/`FLEET_AGENT` configuration. Sunset status comes from the user brief, not those files. Do not overwrite installed aliases or reuse its data directory implicitly. This repo also still has optional `fleet-command` integration in messaging/chain instructions.

Its transport protocol (`capabilities`, `snapshot`, `send`, optional `watch`) is a useful read/send precedent, but cannot replace the lifecycle contract here: it has no spawn, termination, PTY attachment or guarded input. Borrow concepts, not its product identity or database schema automatically. Recommendation: retain “Agent Fleet” as a working description while choosing a distinctive qualified brand; conduct exact package-registry checks once the user shortlists names.

## 6. Staged migration

Sizes are rough engineering effort including tests/docs, not delivery dates: S = days, M = roughly 1–2 engineer-weeks, L = multiple weeks, XL = a separate substantial project. Stages can be split into smaller reviewable changes.

| Stage | Scope and acceptance gate | Size / risk |
| --- | --- | --- |
| 0: v2.0.0 | Ship current tmux work. This research does not expand that release. | No implementation here |
| 1: v2.x seams | Extract internal tmux module, normalized bulk snapshot and settings access; include embedded Perl and generated shell paths. Keep state ownership unchanged. Existing suites and list/open latency budget pass. | M / medium regression risk |
| 2: v2.x identity contract | Add instance/generation bindings and driver event API. Preserve stable agent IDs and conversations. Contract tests cover late hooks, endpoint reuse, rename, reopen, disconnect and shell-target refusal. | M–L / high identity/delivery risk |
| 3: v2.x core state | Move graph/state/accounting and queue namespace behind one store; journal migration, keep rollback data, stop dual authority. Legacy tmux metadata becomes projected state. Retain old paths until cutover is verified. | L / high race/data risk |
| 4: v3 preview | Add versioned adapter runner, fake backend, portable list/board/status and detached delivery scheduling. Prove core commands work with tmux absent from PATH. Select one real second backend and run the same behavioral contract. | L for Zellij/WezTerm proof; XL for new PTY daemon / high |
| 5: v3 release | New product executable plus all compatibility wrappers; backend capability help, installer/config/skills/rules migration, bilingual user docs. Run all offline suites and explicit backend conformance matrix. | M–L / medium-high compatibility risk |
| 6: later | Additional terminal frontends, remote/headless server and optional web attachment; retire aliases only by a separate decision. | L–XL depending on scope |

Test gates use stub Claude/Codex only and private backend instances. Cover FIFO and partial input failure, busy/scrolling clients, no-client headless operation, exit reconciliation, crash/restart, ownership dismissal, accounting pauses and unknown capabilities. Preserve the existing one-snapshot/one-record-pass performance constraint; no busy polling or real paid agent probes are needed for initial extraction. A published adapter contract should include these conformance fixtures.

Open decisions for the user: (1) first non-tmux target: another multiplexer or completely headless? (2) is reduced popup/chip/interactive-open support acceptable per backend? (3) allow mixed backends in one project immediately, or one backend instance per project first? (4) distinctive new brand vs intentionally inheriting the sunset Fleet name? Recommended initial scope is one runtime per project, capability-based UI, compatibility wrappers throughout v3, and no automatic import of sunset Fleet data.
