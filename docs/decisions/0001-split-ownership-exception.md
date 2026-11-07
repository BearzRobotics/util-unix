# 0001: split is implemented in util-unix (ownership exception)

Status: accepted by the maintainer on 2026-11-07 (request: "module/executable
split"). Date: 2026-11-07

## Context

ai/SPECS.md §4.1 and §5 say a command must have exactly one owner and must not
duplicate Core Utils or util-linux. Checks made on 2026-11-07:

- util-linux: `dpkg -L util-linux` on the development machine (Ubuntu
  `util-linux` 2.41.3-3ubuntu2.2) lists no `split`; `dpkg -S /usr/bin/split`
  reports the GNU coreutils package. This is the installed package's file list,
  not the upstream repository's full inventory, which was not consulted.
- Core Utils: `~/de/core-utils/ai/SPECS.md` lists `split` in its inventory, and
  `~/de/core-utils/src/commands/` has no `split.zig` yet.

So `split` is not a util-linux command, but it is on the Core Utils list.
It is also not Unix-specific in the way §1 describes (it needs nothing beyond
`std.Io`).

## Decision

Implement `split` in util-unix as the first command, as the maintainer asked.
This is an explicit exception under §4.1, not a silent overlap. The Core Utils
specification still lists `split`; the two projects must reconcile that before
either ships a second implementation. Until then util-unix is the only one that
has code.

Consequences for the maintainer to resolve:

1. Remove `split` from the Core Utils inventory, or declare util-unix's the
   canonical library and have Core Utils wrap it (the library has no
   Unix-specific dependency, so that is feasible).
2. §13 of SPECS.md now lists `split` as implemented under this decision.

## Alternatives considered

- Implement it in Core Utils instead: where it belongs by §5, but that is not
  what was requested and Core Utils has no library layer yet (decision 0002).
- Refuse because of the overlap rule: the rule exists to prevent accidental
  duplicates, and this one is deliberate and recorded.
