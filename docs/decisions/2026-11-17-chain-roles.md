# Chain roles: one cheap, short-lived agent per job

Date: 2026-11-17 (in progress; discussion log kept for a blog post)

## Context

Seven days of Claude usage (~2.2B tokens, `~/.bin/claude-usage --by agent`) showed 97% cache read: each API call costs roughly the current context size, and each tool call is one call. Secondaries are never cleared and receive the most messages, so they dominate: blog secondary 295M vs its main 152M, tmux-agents 143M vs 91M, peaks 113M vs 82M. Secondaries sent 311 `--notice` vs 2 `--note` messages; about 260 incoming FYI notices each cost a full turn on a large context.

The dotfiles chain asked this chain to reduce the waste. A design agent produced a staged plan; stages 1 and 2 (skill text only) sit unpushed on `feat/chain-token-thrift` (688a076). The user then paused the chain and redesigned the roles directly with main.

## Discussion log

1. **Rotation.** The plan rotated the secondary when a request left the tree clean. The user pointed out that several things run at once, so one secondary would never be idle. Decision: one secondary + worker pair per mission, dismissed at mission end; other missions are unaffected. Each mission has its own worktree; landing is one at a time (rebase, `--ff-only`).
2. **Keeping main on top.** With many pairs, main needs one place to look: a mission board (one row per mission, each secondary edits only its row), mission tags on messages, batched user decisions.
3. **No mission cap.** Main proposed three concurrent missions. The user: "sometimes we were running 10 workers all at once." No cap.
4. **Split the roles.** The user observed main mostly chats, while the secondary mixes delegation, long design sessions and running many commands. Proposed roles: main, interface, designer/planner (UI/UX and engineering), command runner, worker, plus an occasional strong model (Fable) for review or design. Each role gets its own agent type and model.
5. **Main's additions.** Prefer scripts over an LLM command runner (a script costs no tokens); keep a Haiku runner for ad-hoc runs and CI watching. Add a researcher (Sonnet) that reads the codebase and returns a summary. Configure roles in one table and spawn with `--role`. The Sonnet interface makes no judgment calls. Track usage per role. Only main is long-lived.
6. **Flatten dispatch.** The user asked whether interface should dispatch workers directly instead of worker leads spawning more workers. Decision: yes. The designer's plan already splits parts by file ownership and interface, so the interface only dispatches; workers are per task. Depth fits: main 0, interface 1, workers 2.
7. **Who spawns whom.** Whoever consumes the result spawns the agent, and the result goes straight back to it. Main spawns designer and interface; interface spawns workers, reviewer and runner; researcher is spawned by whoever needs facts.
8. **Main stays focused (pull, not push).** Agents update the board and send a note; main reads the board when the user asks. Only urgent events (CI failure, release done) interrupt main. A status-bar count shows missions waiting on the user. Main's context grows with the user's messages, not with agent count.
9. **Talk to the designer directly.** Long design discussions happen in the designer's pane, not through main. The user wants main to (a) know when a design is done and (b) open the designer's pane for them.

10. **Open questions settled.** Rename secondary to interface, keeping `secondary` as an alias. Reviewer defaults to Fable, runner to Haiku. Rework the stage 1+2 branch into the new roles rather than starting over.
11. **Trial run.** The user asked main to build this change by following the new workflow itself, as a beta test: main keeps the main role and dispatches by the plan. Every trial agent carries `wf2` in its name (`claude-tmux-agents-wf2-designer`) so `claude-usage --by agent` can separate trial usage. Trial started 2026-11-17 05:03 UTC.
12. **Parallelize as much as possible.** The user asked what could start without waiting for the designer, and made it a rule: anything that does not depend on a pending design or result starts now as its own mission or task. In the trial, the `tmux-agents open` command split off from the design as mission M2 (Sonnet interface, Codex worker, Fable reviewer), and a Haiku runner recorded the usage baseline, both while the designer worked on M1. A live board (`tmux-agents board --watch`, mission M3) followed so the user can see missions, agents, models and progress in a pane instead of asking main.
13. **Reviewer model.** "Not all reviews have to be done by Fable": reviewers default to Opus; Fable only when the user asks for a Fable review or design.
14. **M1 plan review.** The designer's plan has three parts by file ownership, started at once: the role table (`chain-config --args`), `tmux-spawn --role`, and the skill text reworked on top of 688a076. The user approved the steps and three of its choices: default args apply only while a role keeps its default agent (`none` means no args); `start chain` gains only `--interface` as an alias of `--secondary`; `chain-config` prints all seven roles, labelled `interface`. The env layer confused the user ("too complicated... there are reasons why we were using it. it was for codex i think. if we don't use it wouldn't we break things?"). The existing three role variables stay forwarded and pinned for Codex unchanged; settled with main, the four new roles and all role args get no env layer, only `@tmux_agents_chain_<role>[_args]` and the default. The status-bar count of missions waiting on the user waits a week of the trial.
15. **Trial findings so far.** (1) The M2 interface appended a second M2 row instead of editing its own: hand-edited markdown is fragile, so a `mission set` style command may be needed. (2) A fresh Sonnet interface sat at ~70k context before doing any work, mostly skill text; the reworked skills must be short. (3) A message to the M2 worker was queued as "user typing" with nobody in that pane; possible false positive. (4) Main got repeated "stopped without replying" notes while the designer was, by design, talking with the user; those reminders are noise for a designer in discussion. The user: remove them after this round, once the new system is in place. (5) The user could not see any reviewer: reviewers are short-lived and hidden, so a finished review leaves nothing to look at; the live board (M3) should make them visible while they run.
16. **Mission state leaves markdown.** The user: "maybe we shouldn't be using markdown since we will be building tui / scripts for the board", asking for a CLI plus a DB or schema'd JSON file. Main noted the repo is pure bash/awk with no jq, python or sqlite, so the first version uses one key=value record per mission (like session records) plus an append-only tab-separated log, written atomically and only through `tmux-agents mission add|set|log|show|list` (mission M4). A `--json` view can come later for other tools. Main fixed the format first so M3's board could switch to it in parallel.

17. **Main does not land.** When the user approved landing, main ran the M4 fast-forward and push itself. The user asked: "why are you doing the merges?" Landing is the interface's job; main only grants the turn, so landings stay serialized without main spending its own context on git and CI. From M3 on, each interface lands its own mission (rebase, `--ff-only`, push, watch CI) and replies; the next interface lands after that reply.

18. **Main does not watch either.** Main had started its own background CI watch. The user: "you shouldn't watch things either. if you need start your own cheap agents like sonnet haiku or codex to do it unless they run into problems they can't solve." Main hands every watch or command run to a cheap runner (Haiku, Sonnet or Codex), which notes success and sends a notice only on failure; main steps in only when the runner cannot solve it.

19. **Main's rule, formalized.** The user: "basically your focus is interface with user and delegate any expensive tasks out. right? how would you formalize it to a rule?" Approved wording: main talks and decides, it does not do. It may talk with the user, read mission state, write briefs, send messages and make a lookup of one or two tool calls; everything else goes to the cheapest capable agent (runner, researcher, interface, designer). Test: more than two tool calls or any waiting means delegate. When a delegate is stuck, main decides or asks the user, never fixes it itself.

M5 removes unanswered-request stop notes for every role, following entry 15 (4): "remove them after this round".

## Decisions so far

| Role | Agent / model | Spawned by | Lifetime |
|---|---|---|---|
| main | claude (Opus 5.5) | user | long-lived |
| designer | claude (Opus 5.5; Fable for hard ones) | main | per design |
| interface | claude `--model sonnet` | main, after plan approval | per mission |
| worker | codex | interface | per task |
| reviewer | claude (Opus 5.5 default; Fable only when the user asks) | interface before landing, or main on request | per review |
| runner | scripts first; claude `--model haiku` | interface | per task |
| researcher | claude `--model sonnet` | whoever needs facts | per task |

Mission flow: main spawns designer, user works with it in its pane, plan goes on the board as ready for review, user approves, main spawns interface with the plan, interface dispatches workers and reviewer, lands, reports done, user approves push, main dismisses the interface subtree.

## Open

- Status-bar count of missions waiting on the user: decide after a week of the trial, ideally from a small counts file rather than parsing the board.
