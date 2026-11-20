# Where util-unix has to leave std.Io (for upstream)

A living list of the facilities util-unix and util-core needed that Zig 0.17.1's
`std.Io` / `std.process` do not provide, with what we did instead and what API
would remove the workaround. Every exception lives in `src/sys.zig` (or the two
library files named in decision 0003) and nowhere else, so each row is one place
to delete once std grows the feature. Verified against `~/.zvm/0.17.1/lib/std`.

Entries marked **sh** come from the POSIX shell (decision 0009). Earlier rows
are from util-core decision 0002 and util-unix decision 0003.

| # | Need | What std offers (0.17.1) | What we do | Suggested std API |
|---|---|---|---|---|
| 1 | Signal dispositions (SIGPIPE default, ignore, handlers, masks) | none in `Io`; `std.posix.sigaction` only | `sys.zig` wraps `sigaction`, `sigprocmask` | `Io.Signal` set/get disposition, blocked mask, and a way to receive signals as events (used by `timeout`, `sh` traps) |
| 2 | Process credentials, umask, uname, CPU affinity | none | `sys.zig` queries | `Io.process.Identity`, `umask` get without set-and-restore, `uname`, `cpuAffinity` |
| 3 | File owner/group/device in `File.Stat`; `Dir.setFileOwner` | `Stat` lacks uid/gid/dev; chown not implemented in `Io.Threaded` | `statx`, `fchownat` | add fields and implement `setFileOwner` |
| 4 | `O_APPEND` open, descriptor-level `dup2`, `fcntl(F_GETFD)` | `createFile` has no append mode; no fd-number API | `sys.openAppend`, `dup2` | `OpenFlags.append`; `File.duplicateTo(fd)` |
| 5 | Child wait with timeout / signal events | `Child.wait` blocks, no timeout | `pidfd_open`, `signalfd`, `ppoll`, `wait4` | `Child.waitTimeout`, `Child.pidfd()` |
| 6 | Terminal size beyond yes/no | `File.isTty` only | `ioctl(TIOCGWINSZ)` | `File.terminalSize` |
| 7 | `File.close` reports no error | returns void | cannot report ENOSPC/EIO on close (NFS) | `close() !void` or `closeChecked` |
| 8 | **sh:** `fork()` for subshells, `( )`, command substitution, pipeline stages that are shell code | `Child` only spawns *executables* (`posix_spawn` style); no fork | raw `fork` via `std.os.linux` in `sys.zig`, child continues interpreting | a supported fork-safe story: documented single-threaded `Io` mode in the child, or `Io.process.fork` that quiesces `Io.Threaded` workers |
| 9 | **sh:** the `Io` runtime is multi-threaded; forking it leaves workers missing in the child | `Io.Threaded` spawns workers lazily | the shell builds its `Io` from `Threaded.init_single_threaded` and never starts workers | document that mode as fork-safe, or expose `Io.Threaded.afterFork()` |
| 10 | **sh:** arbitrary fd redirections (`3>file`, `2>&1`, `<&-`, `exec 4<f`), here-documents | `SpawnOptions` takes only stdin/stdout/stderr `StdIo` plus `inherit_files` (no target fd number) | `dup2`, `fcntl`, `pipe2` in `sys.zig`; applied in the forked child | `SpawnOptions.fd_map: []const struct{ child_fd, File }` |
| 11 | **sh:** raw `pipe()` returning two `File`s | only inside `Child` spawn | `pipe2(O_CLOEXEC)` | `Io.File.pipe(io) ![2]File` |
| 12 | **sh:** job control: `setpgid`, `tcsetpgrp`, `tcgetpgrp`, `WUNTRACED`/`WCONTINUED` wait, `SIGTSTP`/`SIGCONT`, process groups | `SpawnOptions.pgid` exists; no foreground handoff; `Child.wait` has no stopped/continued states | `sys.zig` wraps `setpgid`, `tcsetpgrp`, `wait4` with `WUNTRACED` | `Child.waitAny(flags)`, `Io.Terminal.setForeground(pgid)` |
| 13 | **sh:** terminal modes (raw input for line editing, `stty` state save/restore) | `std.posix.tcgetattr` exists, not in `Io` | `sys.zig` wraps termios | `Io.Terminal.makeRaw()/restore()` |
| 14 | **sh:** `read -t` timeout, reading a single byte without buffering over-read | `File.readStreaming` blocks | `poll` then `read` | `File.readTimeout` |
| 15 | **sh:** `ulimit` (`getrlimit`/`setrlimit`), `times`, `umask` set | `std.posix` only | `sys.zig` | `Io.process.limits`, `times` |
| 16 | **sh:** exec that keeps the caller's chosen environment and argv[0] without searching `PATH` itself | `std.process.replace` exists; `PATH` lookup always uses the parent environment | the shell does its own `PATH` search (needed anyway for hashing) then `execve` | fine as is; note the `PATH` rule in the doc comment |

When you hit a new exception: add a function to `sys.zig`, a row here, and a row
in the decision it belongs to. Do not call `std.posix`/`std.os` from a command or
library module.
