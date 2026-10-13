# Configurable chain roles

Date: 2026-10-13

## Context

The shell launcher chose Claude as main, the skill chose Claude as secondary, and only worker selection was configurable. Users need independent role choices and must retain existing account preferences in their instruction files.

## Decision

- Every role accepts `claude`, `codex` or an exact configured Codex profile name. Defaults remain `claude`/`claude`/`codex`. A `codex` prefix alone does not identify a valid profile.
- Store preferences in `@tmux_agents_chain_main`, `@tmux_agents_chain_secondary` and `@tmux_agents_chain_worker`, with corresponding `TMUX_AGENTS_CHAIN_MAIN`, `TMUX_AGENTS_CHAIN_SECONDARY` and `TMUX_AGENTS_CHAIN_WORKER` overrides.
- Precedence is this-chain explicit user choice or CLI flag, applicable user instruction-file role preference, non-empty environment override, non-empty option, then default. The skill passes file preferences as explicit choices; shell commands never parse Markdown. An existing worker instruction continues to win until the user removes or replaces it when migrating to settings.
- Main configuration applies only to `tmux-agents start chain`. An existing top-level agent asked to start a chain stays main. The shell selects main before it can read instruction files, so that initial choice uses CLI/environment/options/defaults.
- Add `--main`, `--secondary` and `--worker` to `start chain`. Validate all choices before creating a window, and include their values and sources in the initial prompt. Preserve the distinction between explicit choices and configuration snapshots.
- Provide read-only `tmux-agents chain-config [role]` with the same override flags and `--sources`, without `--from` or any agent-state mutation. All-role output is ordered TSV role/value rows; sources add a third column (`explicit`, `env`, `option`, `default`). A selected role prints just its value unless sources are requested. Selected-role queries validate only that role. Errors emit no partial result. Outside tmux (`TMUX` unset), queries use environment/default lookup without contacting the default server; an unreachable configured `TMUX` socket is an error.
- Forward explicit role environment overrides and profile mappings across launch boundaries and pin them for Codex sessions. Do not convert every resolved setting into an environment override or add a role global-environment fallback.
- Main keeps agent permission defaults. Members follow `sub_auto`, default `on`. Codex main is supported with identity pins and notify; main reports progress for each new user task because Codex has no turn-start hook.
- Main still creates both members at depth 1; secondary coordinates its assigned worker, whose ordinary helpers are depth 2. Settings affect new chains only, not live role swapping, member ownership or resume identity.

## Why

This makes roles independent of agent kind while preserving user instructions, account identity, permission choices and the existing member workflow. A read-only resolver lets the CLI and skill share validation without a second configuration parser.

## Rejected

- Silently letting an option override an existing instruction-file preference.
- Replacing an existing main agent or restarting it after reading a different main preference.
- Matching arbitrary `codex*` names, accepting arbitrary executables or adding model configuration.
- Treating option/default snapshots as permanent environment overrides, or claiming Codex notify supplies a turn-start hook.

See [Configuration](../configuration.md#chain-roles) for usage and migration, and [Environment](../design/environment.md#top-level-launch-and-tracking) for launch propagation.
