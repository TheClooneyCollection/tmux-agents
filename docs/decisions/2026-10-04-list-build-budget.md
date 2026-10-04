# The agent list is built from one snapshot, within a process budget

**Context.** Opening `prefix + a` and switching scope with `ctrl-t` took 4.5 to 4.9 seconds on 32 panes and 45 session records: one list build forked about 220 tmux, 230 awk, 145 basename and 21 git processes, from per-agent name lookups and per-step ancestor walks.

**Decision.** A list build takes one `tmux list-panes -a` snapshot and reads the session records once. Every lookup and ancestor walk works in memory from those, and a directory's project is computed once per build. New features follow the same rule: never one external command per agent or per ancestor step.

`tests/list-budget.sh` enforces it: on an isolated server with about 50 panes and 100 session records (nested parents, closed ancestors) it builds both scopes and fails if a build launches more than about 20 external processes (counted through a PATH shim) or takes longer than a loose time cap.

**Why.** The list is opened many times a day and must feel instant; the slowdown crept in one feature at a time, so it needs a guard, not a one-off fix.
