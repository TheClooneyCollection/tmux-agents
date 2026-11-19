# Claim an existing agent's chain role

An agent started outside the chain launcher can already be the main while lacking
`@role`, so the mission board cannot pin it. Let a live named top-level agent claim its own
role with `tmux-agents role ROLE [--from ME]`, including `secondary` as an alias
for `interface`. Initialize missing tracking and identity through existing helpers.
Repeated claims are harmless; an existing different role is refused to preserve
spawned assignments. Parented helpers cannot claim any role. There is no force
override or peer target.

Status keeps its role display and adds a claim hint only for the caller when
`@parent` and `@role` are empty, never for `status PEER`. Main
claims its role when starting or joining an existing chain without one.
