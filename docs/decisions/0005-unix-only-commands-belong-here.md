# 0005: Commands that only make sense on Unix belong to util-unix

Status: accepted by the maintainer. Date: 2026-11-07
(request: "Those commands are unix only they don't make sense in a
cross-platform environment so they need to be moved to util-unix")

## Context

SPEC §5 requires one owner per command. When this decision was made, the Core
Utils project (`~/de/util-core`) already implemented `chmod`, `chown`, `chgrp`,
`id`, `groups`, `tty` and `uname` (and `split`, which left util-unix earlier,
see below), while SPEC §5 proposed `chmod`, `chown` and `chgrp` for util-unix
and left `tty` and `uname` open. `chown` and `chgrp` were therefore in both
projects. Checked 2026-11-07 by listing `~/de/util-core/src/commands/`; the
upstream util-linux inventory was not consulted for these names (none of them
is a util-linux command).

## Decision

Ownership follows platform semantics, not GNU package membership (SPEC §1, §5):

- util-unix owns `chmod`, `chown`, `chgrp`, `id`, `groups`, `tty`, `uname` and
  `getent`. Their meaning depends on Unix permission, identity and terminal
  facilities, so a cross-platform Core Utils cannot implement them honestly.
- Core Utils keeps portable commands, including `split`. `split` was removed
  from util-unix in commit 4f2ba4c; its decision record (0001, an explicit
  ownership exception) went with it.
- Each moved command is a library module plus a thin wrapper here (decision
  0002), not a copy of the Core Utils single-file implementation.

## Consequences

- The Core Utils copies of the seven commands become duplicates and must be
  removed there; until they are, SPEC §5 is violated across the two projects.
  That removal is a change to the other repository and is tracked by the
  maintainer, not done by this repository.
- Core Utils' `mkdir -m` needs the same mode grammar as `chmod`; it keeps its
  own `mode.zig` rather than depending on util-unix (SPEC §5: neither project
  depends on the other).
- Differential tests moved with the commands (`test/test_<cmd>.sh`).
