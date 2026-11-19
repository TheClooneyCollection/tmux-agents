# Toggle completed missions while watching

The user asked for a key to expand the earlier completed missions on the live board.

In terminal watch mode, `a` toggles between the default folded view and all missions,
including their completion outcomes. `--all` sets the initial expanded view. Changes
appear immediately. A dim footer advertises `a all missions · q quit`; `NO_COLOR`
keeps the hint without colour. `q` and Ctrl-C restore the terminal before exiting.

Keep the existing animation cadence and non-terminal behaviour. Requiring a restart
with `--all`, or waiting until the next scheduled refresh, would interrupt inspection.
