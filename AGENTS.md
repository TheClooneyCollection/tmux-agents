# AGENTS.md

Notes for AI agents working on tmux-agents.

## Testing

- **Never touch the user's tmux server.** Test on your own socket: `tmux -L <testname>`.
- Before pointing `TMUX=` at a test socket, check the server is up (`tmux -L <testname> has-session`) and the socket path is non-empty and not `*/default`. A failed test server plus an empty `TMUX` falls back to the user's server.
- Clean up with `tmux -L <testname> kill-server` only. Never run a bare `tmux kill-server`. Suites use `tests/helpers/cleanup.sh` to stop their delivery workers and remove only their own queue directory before deleting temporary state; never remove `default/` or shared flat-root messages.
- Test servers use `set -g default-shell /bin/sh`, so the user's shell config doesn't run in test panes.
- Stub both agents: point `TMUX_SPAWN_BIN` at a directory with `claude` and `codex` scripts that print a marker and `exec cat`, and check the marker before going on. In `tmux-spawn`, the agent type comes before the options.
- Run every suite before a release; each file's header says what it covers:

  ```sh
  for t in tests/*.sh; do /bin/bash "$t" </dev/null || echo "FAILED $t"; done
  ```

  `</dev/null` matters: `tmux-spawn` reads a task from stdin when given none, so a test without it can hang.
- After touching something, run at least:

  | Touching | Run |
  | --- | --- |
  | working-time counters, state transitions or persistence | `worked-time.sh`, `work-checkpoints.sh`, `list-layout.sh` plus the message and lifecycle suites |
  | `tmux-agent-report`, `tmux-ask`, the skills' messaging rules | `needs-you.sh`, `ask-queue.sh`, `resume-messages.sh` |
  | `tmux-agents` (list, chip, picker) | `list-budget.sh`, `list-scope.sh`, `msg-waiting-ui.sh`, `skill-links.sh`, `preview-header.sh` |
  | `tmux-spawn` | `spawn-for.sh`, `spawn-split.sh`, `spawn-names.sh`, `resume-messages.sh`, `sub-auto.sh` |
  | member lifecycle (spawn, depth, ownership, dismiss, resume; owner A) | `tests/members.sh` |
  | member UI (list, chip, attention; owner B) | `tests/member-ui.sh` |
  | user settings or configuration lookup | `settings.sh`, `spawn-names.sh`, `list-budget.sh`, `install.sh`, `skill-links.sh` |
  | top-level launcher, shared launch hooks or pins | `tests/launcher.sh`, `tests/start-takeover.sh`, `tests/tracking.sh`, `spawn-for.sh`, `spawn-split.sh`, `settings.sh` |
  | tracked state, untracked rows or message transitions | `tests/tracking.sh`, `needs-you.sh`, `worked-time.sh`, `list-budget.sh`, `preview-header.sh` |
  | skills or installer | `skills.sh`, `install.sh`, `skill-links.sh` |
  | `tmux-dismiss` | `dismiss.sh` |
  | agent IDs, record migration or identity lookup | `agent-ids.sh`, `lifecycle-ids.sh`, `list-ids.sh`, `live-names.sh` plus the message suites |
  | naming, rename or target lookup (`lib.sh`, `tmux-rename`, `tmux-connect`) | `rename.sh`, `names.sh`, `live-names.sh`, `spawn-names.sh`, `ask-queue.sh`, `resume-messages.sh` |

- CI entry points and dependencies are documented in [ci/README.md](ci/README.md). Run `ci/static.sh` and `ci/docs.py` when changing shell scripts or documentation; `ci/suites.sh` runs all offline suites and keeps their logs. Installation, upgrade and pinned skills CLI checks have separate local entry points.
- Every fix gets a test that fails without it; every new workflow gets a case in its suite.
- **A flaky test blocks the release** until its cause is known. Rerun a suspect suite about ten times with background CPU load, and fix the cause, never with a sleep. Async tests wait for explicit conditions and assert on a message's identity (its body and `.meta`), not on how many files a directory holds.
- Target bash 3.2 (macOS): see [environment](docs/design/environment.md#macos-bash-32) and [pitfalls](docs/design/pitfalls-and-testing.md).

## Rules that keep it fast and correct

- **The list build has a budget:** one `tmux list-panes -a` snapshot and one read of the session records per build, lookups and ancestor walks in memory, never an external command per agent or per ancestor step. A change to the open path measures start→fzf and start→first rows. See [docs/performance.md](docs/performance.md) and its [decision](docs/decisions/2026-10-04-list-build-budget.md); `tests/list-budget.sh` enforces it.
- **Sub agent states** (working, idle, done, needs you, permission, message waiting): before changing how `@state` or its markers are set, read [docs/design/sub-agents.md](docs/design/sub-agents.md) ("Done state and cleanup") and add a `needs-you.sh` case for the workflow.
- **Decisions first:** record behaviour changes the user decides in [docs/decisions/](docs/decisions/README.md), one file each, indexed in its README, and answer UX questions before building.

## Working together

- Agents may share one checkout. Agree file ownership first and hand over shared files in turn. Commit only your own paths (`git commit -- <paths>`), never `git add -A` while others are working; reread HEAD and your diff before committing; never reset, stash or rebase over others' uncommitted changes (push directly if origin hasn't moved, otherwise coordinate).

## Layout

`bin/` commands, `tmux/tmux-agents.conf` bindings and hooks, `skills/` (one folder per skill, shared by Claude and Codex: `tmux-agents`, whose Codex sandbox section only applies to Codex, `tmux-agents-setup`, `tmux-agents-perf` and `agent-chain`; keep each at `skills/<name>/SKILL.md` so `npx skills` finds them), `integrations/` per-tool glue, `install.sh`, `tests/`. Docs: README (users), `docs/guide.md` (details), `docs/configuration.md` (user settings and overrides), DESIGN.md and `docs/design/` (how and why), `docs/decisions/` (what the user decided), `docs/performance.md`. Keep them and the skills in sync when behaviour changes. No em dashes; keep the README short and move details to the guide.

**README.zh-CN.md must always match README.md.** Any change to README.md updates README.zh-CN.md in the same commit: same sections in the same order, same commands, links and code blocks, in natural Chinese rather than word for word.

## Commits and releases

- Commit style: `feat: ...`, `fix: ...`, `docs: ...`, `test: ...`, `chore: ...`.
- Merge PRs with rebase merges only (`gh pr merge N --rebase`), never merge commits or squash, so main's history stays linear. Rebase a branch onto main before merging it. The GitHub repo allows only rebase merging, and rulesets on main require linear history and the 7 CI jobs (admins may bypass). Never use `gh pr merge --admin` to skip red or pending CI unless the user says so.
- Release: turn CHANGELOG.md's "Unreleased" into the version (semver: minor for new options or changed behaviour, patch for fixes and docs), run every suite, commit and push, then `gh release create vX.Y.Z --target main` as a separate step. Before tagging, check new messages, HEAD and existing tags; a hold on the release must be lifted explicitly.
- Reply as soon as the release is out; send follow-ups (syncs, announcements) as notices.
- Never move or delete a published tag. If something missed a release, ship a follow-up patch.
- After releasing, update your installed copy as your local setup describes (maintainers: see your dotfiles' instructions). Develop only in this repo, never in an installed copy. When a task says not to release or update, don't, and say in your reply what's left.
