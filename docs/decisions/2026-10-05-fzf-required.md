# fzf is required for the agent list

The README called fzf optional, but `prefix + a` already required it and its
missing-dependency error disappeared with the popup.

Require fzf for the agent list, while keeping other commands usable without it.
Installation checks for fzf and prints package commands if missing, but succeeds.
An interactive list popup keeps its instructions visible until a key is pressed;
redirected input never waits. Preserve the missing-dependency exit status of 1.
Do not add a display-menu fallback or install system packages automatically.
