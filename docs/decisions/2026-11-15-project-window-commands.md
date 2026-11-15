# Commands in configured project windows

The user wants the fleet dashboard server to start alongside configured project windows.

Add `command=CMD` to main-sequence records and their add/set/unset commands. Parse it as one shell-quoted token without evaluating it. A command row opens a plain window in the configured directory; `shell` is redundant and `resume` is ignored with a warning. Preserve names by disabling both window rename options.

Execute the command with the server's default shell, falling back to SHELL and then /bin/sh. After the command exits, including a nonzero exit or an explicit exit statement, start an interactive instance of the same shell so the output stays available.

A special dashboard-only launcher and evaluating commands during config parsing were rejected. This is a general per-window command, independent of the custom chain-agent override. Existing shell and chain rows keep their launch behavior.
