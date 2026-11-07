# 0003: Exceptions to the std.Io rule

Status: accepted. Date: 2026-11-07. Same reasoning as Core Utils decision 0002.

ai/AGENTS.md §13 requires `std.Io` "unless there is a compelling reason not to".
Audited against `~/.zvm/0.17.1/lib/std` (Zig 0.17.1) on 2026-11-07:

| Used | Where | What | Why std.Io cannot |
|---|---|---|---|
| `sigaction` for SIGPIPE | `src/sys.zig`, called only by the entry points (`exe.zig`, `multicall.zig`) | restore the default disposition at start-up | `std.Io` has no signal API; Zig's runtime ignores SIGPIPE, which would turn `cmd \| head` into a write error |
| `getuid`/`geteuid`/`getgid`/`getegid`/`getgroups`, `umask`, `uname` | `src/lib/proc.zig` (library) | credentials of the process, the file-mode creation mask, `utsname` | `std.Io` has no credentials, umask or utsname API (checked 2026-11-07 against `~/.zvm/0.17.1/lib/std/Io*`). They read process or machine state; only `umask` has a side effect, because the syscall has no query form (set to 0, restore), which is why it is read once at start-up. |
| `statx`, `fchownat` | `src/lib/fsown.zig` (library) | owner, group and device of a file; change owner | `File.Stat` lacks uid/gid/dev and `Dir.setFileOwner` is not implemented in `Io.Threaded` |

Unlike the entry-point `sigaction` above, these two library files are the only
places the library leaves `std.Io`. Other systems get neutral values
(`proc.zig`) or `error.Unsupported` (`fsown.zig`).

Everything else in the library (`src/lib/`) uses `std.Io`: `Io.File` and
`Io.Dir` reads, writes, `statFile`, `setFilePermissions`, directory iteration,
`readLinkAbsolute`, `File.isTty`.

One smaller gap is worked around by documenting it rather than by `std.posix`:
`File.close` returns no error, so a failed close (for example ENOSPC on NFS)
cannot be reported.
