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
| 17 | **sh:** descriptor-number I/O: `open` returning a number, `read`/`write` on fd 0/1/2 and arbitrary fds, `close`, `lseek` (redirections, `read` builtin, builtin output) | `Io.File` wraps a handle but `Io.File.stdin()` etc. are the only way to name 0-2; no `File.fromFd(n)`; no way to write to "whatever fd 1 is now" after `dup2` without rebuilding a `File` | `sys.open`, `read`, `writeAll`, `close` via `std.os.linux` | `Io.File.fromHandle(n)` (borrowed) and a documented guarantee that `Io.File.stdout()` follows `dup2` |
| 18 | **sh:** `dup`, `dup2`, `fcntl(F_DUPFD_CLOEXEC)`, `FD_CLOEXEC`, "is fd n open" | none (row 4 covers dup2 for `nohup`) | `sys.dup`, `dup2`, `dupAbove`, `setCloexec`, `fdIsOpen` | `File.duplicate()`, `File.duplicateTo(n)`, `File.setCloexec`, `File.isOpen(n)` |
| 19 | **sh:** anonymous in-memory file for here-documents of any size | no `memfd_create`; a pipe would deadlock for bodies over the pipe capacity | `sys.memfileWith` (`memfd_create` + write + `lseek`) | `Io.File.createAnonymous(io, bytes)` |
| 20 | **sh:** `wait4` for one child with EINTR reported, status decoding (exit code, termination signal, core dump bit) | `Child.wait` returns `Term` but only for spawned `Child` values and swallows EINTR | `sys.waitpid`, `statusCode`, `statusSignal` | `process.waitPid(pid, flags)` returning `Term` and reporting interruption |
| 21 | **sh:** `stat`/`lstat`, `access(2)` with real ids, directory listing without an `Io.Dir` handle per call (`test`, `$PATH` search, pathname expansion) | `Io.Dir.statFile` lacks uid/gid/device (row 3) and `access` | `sys.stat`, `sys.fstat`, `sys.access`, `sys.listDir` (`getdents64`) | `Dir.access(path, mode)`, `File.Stat` with uid/gid/dev/ino |
| 22 | **sh:** change and read the working directory by path (`cd`, `pwd`) | `process.setCurrentDir(io, Dir)` needs an open `Dir`; no `getcwd` returning the kernel's physical path into a caller buffer | `sys.chdir`, `sys.getcwd` | `process.chdir(io, path)`, `process.getCwd(io, buf)` |
| 23 | **sh:** `umask` set (row 2 has the read), `getrusage` (`times`), `getrlimit`/`setrlimit` (`ulimit`) | none (row 15) | `sys.umaskSet`, `cpuTimes`, `getrlimit`, `setrlimit` | `process.umask`, `process.cpuTimes`, `process.limits` |
| 24 | **sh:** async-signal-safe "pending flag" signal handlers, disposition query, `kill(pid, sig)` to any process, signal names | none (row 1) | `sys.setSignal` (default / ignore / flag handler, no `SA_RESTART`), `getSignal`, `takePending`, `kill`, `signalNumber` | `Io.Signal.onSignal(sig, *atomic flag)` and `Io.Signal.send(pid, sig)` |
| 25 | **sh:** terminal attributes: get/set termios, raw mode for the line editor, erase/kill/EOF characters | `std.posix.tcgetattr` exists, not in `Io` (row 13) | `sys.tcgetattr`, `tcsetattr`, `termiosRaw`, `termiosChars` (kernel `struct termios`) | `Io.Terminal.makeRaw()/restore()` |
| 26 | **sh:** process groups and the controlling terminal: `getpgrp`, `setpgid`, `tcgetpgrp`, `tcsetpgrp` (job control) | `SpawnOptions.pgid` only | `sys.getpgrp`, `setpgid`, `tcgetpgrp`, `tcsetpgrp`, `killpg` | `Io.Terminal.setForeground(pgid)`, `process.setPgid` |
| 27 | **sh:** `wait4` with `WUNTRACED`/`WCONTINUED`/`WNOHANG`, decoding stopped and continued states | `Child.wait` has no stopped/continued states (row 12) | `sys.waitpidFlags`, `statusStopSignal`, `statusContinued`, `statusCoreDumped` | `process.waitAny(flags)` returning a `Term` with `.stopped`, `.continued` |
| 28 | **sh:** wait for input with a timeout (ESC versus escape sequence, `TMOUT`), terminal size, `SIGWINCH` | `File.readStreaming` blocks; no timeout (row 14) | `sys.pollIn`, `sys.winsize` | `File.readTimeout`, `File.terminalSize` (row 6) |

When you hit a new exception: add a function to `sys.zig`, a row here, and a row
in the decision it belongs to. Do not call `std.posix`/`std.os` from a command or
library module.
