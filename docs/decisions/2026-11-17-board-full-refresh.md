# Print the full mission board on every refresh

A tall mission board was clipped to the pane height, hiding agents behind a
more-rows marker. Watch mode now prints every row on every refresh, preserving
width fitting. Users navigate with tmux copy-mode; there is no pager or new TUI.
Height clipping and the hidden-row count are removed.
