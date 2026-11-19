# Mission outcomes and pinned main

The board should make completed work readable without stale owner warnings and
keep the project main visible independently of mission ownership.

The user chose dimmed last-done log outcomes, highlighted missing owners for
unfinished missions with their latest log text, three recent completed missions
expanded by default, and `--all` to show all completed missions. Completion time
comes from the last done entry, falling back to the record update timestamp.
Names omit agent and project prefixes unless ambiguous. The project main, marked
`@role main`, and its subtree are pinned above missions; each agent appears once.
When a descendant owns a displayed mission, the pinned traversal stops before
that owner so its tree appears under the mission instead. Owners of folded done
missions remain in the pinned tree; expanding those missions moves their trees
under their mission headers. No placeholder is required in the pinned section.
An empty unassigned section is hidden. Width fitting, NO_COLOR and watch animation
continue to apply.

A reopen command is omitted: `tmux-agents open` only accepts live panes. Keeping
all completed missions expanded and showing absent-owner warnings on completed
work were rejected because they obscure current work and its outcomes.
