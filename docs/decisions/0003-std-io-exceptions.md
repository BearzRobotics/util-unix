# 0003: Exceptions to the std.Io rule

Status: accepted. Date: 2026-11-07. Same reasoning as Core Utils decision 0002.

ai/AGENTS.md §13 requires `std.Io` "unless there is a compelling reason not to".
Audited against `~/.zvm/0.17.1/lib/std` (Zig 0.17.1) on 2026-11-07:

| Used | Where | What | Why std.Io cannot |
|---|---|---|---|
| `sigaction` for SIGPIPE | `src/sys.zig`, called only by wrappers (`exe.zig`, `multicall.zig`, `commands/split.zig`) | default disposition at start-up; ignore while a `--filter` runs | `std.Io` has no signal API; Zig's runtime ignores SIGPIPE, which would turn `split ... \| head` into a write error |

The library (`src/lib/`) uses `std.Io` for everything: `Io.File` read/write
(streaming and positional), `Io.Dir.createFile`/`openFile`, `File.stat`,
`File.setLength`, `std.process.spawn` and `Child.wait` for filters.

Two smaller gaps, both documented in docs/compatibility/split.md rather than
worked around with `std.posix`:

- `File.close` returns no error, so a failed close (for example ENOSPC on NFS)
  cannot be reported.
- `File.Stat` has no device number, so "output would overwrite input" compares
  the inode number only, and only for a regular-file input.
