# Polish the mission board

The board worked but was plain: uncoloured text, an `Owner:` line repeating
the tree's first row, missions oldest first and agents in pane order.

Decision (user, 2026-11-17):

- Rows lead with the agent list's status glyph, then the short name, a dim
  `kind · model`, the status word (omitted for working) and dim activity.
  Colours reuse the list and chip palette. The `Owner:` line is shown only when
  the owner is not live.
- Siblings in each tree sort by the list's rank: permission, then needs you or
  message waiting, then working, idle, done. Equal ranks keep pane order.
- Missions sort newest created first.
- In `--watch`, working glyphs spin with the chip's frames at
  `@tmux_agents_chip_fps`. Data still refreshes at the watch interval. A board
  that fills or exceeds the pane steps one frame per refresh, since tick
  repaints would scroll it.
- Colour only on a terminal and only without `NO_COLOR`; piped output stays plain
  text with a static `⠿` for working.

Rejected: colouring the old layout unchanged; ranking only working rows first;
stepping the spinner once per data refresh (it looks stuck at 2 seconds).

Implementation: Bash 3.2 accepts only whole seconds for `read -t`, so animation
ticks use Perl `select` to wait for input with a fractional timeout. Watch saves
the terminal settings, disables canonical input and echo, and restores the
settings and cursor on exit. Data refresh waits use the same helper, avoiding
Bash restoring its own temporary input mode after an interrupt.
