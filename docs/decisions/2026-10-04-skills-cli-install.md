# Skills install with the skills CLI; no Claude Code plugin yet

**Context.** The user wants tmux-agents to be installable as agent skills, the way other tmux tools reach users through `npx skills add` and skills.sh, and wants the agent chain from their own CLAUDE.md shipped as a skill.

**Decision.**

- Every skill lives at `skills/<name>/SKILL.md` and is shared by Claude and Codex, so `npx skills add TheClooneyCollection/tmux-agents -g` finds each one once. The `tmux-agents` skill is one file; its Codex sandbox section says it only applies to Codex.
- The skills CLI provides user-level skill installation alongside `install.sh`. The `tmux-agents` skill checks that the commands exist and otherwise offers the `tmux-agents-setup` skill, which runs `install.sh` for commands, skills and rules.
- The installer does not migrate CLI canonical copies (such as `~/.agents/skills/`) or CLI lock metadata. Duplicate skill sources remain outside this change's scope and are managed manually by the user.
- Updates and re-linking run from the actual installed checkout: `git pull --ff-only` on a branch, or `git fetch --tags` and checkout of the user-selected new tag for detached/tag installs, then `./install.sh`. At link destinations, `--force` backs up real files and directories as `DEST.bak.YYYYmmddHHMMSS` before linking.
- The agent chain is the `agent-chain` skill. The worker is `codex` unless the user names another agent or Codex profile.

**Why.** The two copies of the `tmux-agents` skill had the same name at the same depth, so the skills CLI would pick one of them. One shared folder per skill also matches what other skill tools expect.

**Rejected for now: a Claude Code plugin** (`.claude-plugin/marketplace.json`). A plugin puts its root `bin/` on Claude's PATH while it's enabled, so Claude would run the plugin's pinned copy of the commands while tmux and Codex run the ones `install.sh` linked. It also can't do the tmux, PATH and Codex wrapper steps. Revisit if the commands move out of `bin/` or the plugin can do the rest of the install.

**CI verification.** `ci/skills-cli.sh` runs the real `skills@1.5.12` package against the local checkout, with a temporary HOME, CODEX_HOME, XDG directories, npm cache and working directory. It disables telemetry and stubs tmux. Ordinary test suites stay offline.

The npm release identifies commit [e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f](https://github.com/vercel-labs/skills/tree/e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f). Its [help](https://github.com/vercel-labs/skills/blob/e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f/src/cli.ts) and [add parser](https://github.com/vercel-labs/skills/blob/e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f/src/add.ts) support `--list`, `--global`, `--agent`, `--skill`, `--yes` and `--copy`. This version has no install mock or dry-run option; `--list` only discovers skills. Do not pass an assumed `--dry-run`: the add parser ignores unknown options. The checkout's own `./install.sh --dry-run` is separate.

In this version, [Codex is a universal agent](https://github.com/vercel-labs/skills/blob/e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f/src/agents.ts), and the [installer](https://github.com/vercel-labs/skills/blob/e3a5432e888ef415f4d2bfb2d1d427dcf9a23b1f/src/installer.ts) uses `~/.agents/skills` for it. The default mode links Claude's skills there; `--copy` instead gives Claude real directories. CI tests both modes, then runs `install.sh --force`: old links are replaced without backups, copied Claude directories receive timestamped backups, and Codex receives checkout links. Canonical CLI copies remain intact.
