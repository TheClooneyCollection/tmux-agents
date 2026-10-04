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
