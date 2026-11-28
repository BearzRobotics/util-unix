# 0011: Where the shell leaves std.Io

Status: accepted by the maintainer. Date: 2026-11-28.
Extends decision 0003 to `sh`.

## Rule

ai/AGENTS.md §13 requires `std.Io` unless there is a compelling reason, which
the maintainer approves. For the shell the maintainer chose (2026-11-28) to use
`std.Io` where it works and to document why it does not fit elsewhere. `std.Io`
is still young in Zig, so every reason below is about Zig 0.17.1 and should be
checked again when the toolchain changes.

All direct system calls stay in `src/sys.zig`. They are Linux only. A port, if
someone asks for one, would be to another Unix system (macOS, the BSDs, Redox);
none is planned.

Checked against `~/.zvm/0.17.1/lib/std` by reading the source. The calls in
"Moved to std.Io" were then moved and tested.

## Exceptions: no std.Io equivalent found

| Calls | Used for |
|---|---|
| `fork` | subshells, command substitution, pipeline stages that are shell code |
| signals: set and query disposition, block, wait, pending flags, `kill`, `killpg` | `trap`, `kill`, Ctrl-C, job control |
| `wait4` with `WNOHANG`, `WUNTRACED`, `WCONTINUED`; looking at a child without reaping it | `wait`, background and stopped jobs (`Child.wait` covers only processes `std.process` started) |
| `getpgrp`, `setpgid`, `tcgetpgrp`, `tcsetpgrp` | job control |
| terminal modes (`tcgetattr`, `tcsetattr`) and window size | line editor, `read` |
| `poll`, clearing `O_NONBLOCK` | line editor and script input |
| `pipe2`, `dup`, `dup2`, `fcntl` (duplicate above 10, close-on-exec, is open), `close` of a bare number | pipelines and redirections, where scripts name descriptors by number |
| `memfd_create` and `lseek` | here-documents of any size |
| `getrlimit`, `setrlimit`, `times`, `umask` | `ulimit`, `times`, `umask` |
| process and user ids, dropping privileges | `$$`, `$PPID`, prompts, `-p`, `test` (shared with decision 0003) |
| error number and its message text | diagnostics worded like other shells' |

## Exceptions: std.Io has the operation, but it does not fit

| Operation | Why it does not fit |
|---|---|
| `open`, `read`, `write` on the shell's descriptors | `Io.Threaded` retries a call that a signal interrupted. The shell must get control back to run a trap or act on Ctrl-C while an open of a FIFO or a read is waiting. Redirections also need append mode and descriptors that survive `exec`; `Dir.createFile` has no append option and `Io.Threaded` opens close-on-exec. |
| waiting for the history file lock (`flock`) | `File.lock` retries after a signal in the same way, so the wait could not be interrupted. |
| running a program (`execve`) | `std.process.replace` is documented as illegal in a forked child, which is where the shell runs external commands. |
| file information (`statx`) | `File.Stat` has no owner, group or device. `test -O`, `-G` and `-ef`, the check that `$PWD` names the current directory, and history file ownership need them. All `stat` calls stay on one wrapper rather than two. |
| saving to disk (`fsync`) and giving a file to its owner (`fchown`), both for the history file | `Io.Threaded` treats `EINVAL` (and for `fsync` also `EROFS`) as a programming error: a debug build panics, a release build loses the error number. Linux can return both: `EINVAL` from `fchown` to an owner that has no id in a user namespace, `EROFS` from `fsync` after a file system has turned read-only (from the system's documented behaviour; not reproduced here). `Dir.setFileOwner` is not implemented and panics. |
| listing a directory (pathname expansion, completion) | `Io.Threaded` does not name `EIO` from opening or reading a directory. A glob that cannot be read fails with a message, which would become "Unknown error" for a failing disk. |
| reading the history file | it is read from the descriptor that holds the lock (see `flock`) |

## Moved to std.Io

All in `src/lib/sh/osio.zig`, except the two noted.

| Was in `sys.zig` | Now |
|---|---|
| `access` | `Dir.access` (real ids, as before) |
| `chdir`, `getcwd` | `process.setCurrentPath`, `process.currentPath` |
| `rename`, `unlink`, `readlink` | `Dir.rename`, `Dir.deleteFile`, `Dir.readLink` |
| `isatty` | `File.isTty`, which asks for the window size rather than the terminal modes; also used by `commands/sh.zig` |
| `random32` | `Io.randomSecure`. Not `Io.random`: it seeds a generator once, and `fork` would copy it, so parent and child could make the same temporary file names |
| reading `/etc/passwd` for `~user` (`expand.zig`) | `Dir.readFileAlloc` |

`std.Io` reports errors as Zig error values. `osio.zig` turns them back into the
system's error numbers, so messages are unchanged for every error `std.Io`
names. An error it does not name now reads "Unknown error"; for these calls
that is left only for errors they are not expected to give (for example a
lost network file system while saving history).

Reading scripts and startup files stays with the second table, because those
paths can be FIFOs.

## Consequences

- `Env.io` stays and is used for the moved calls. The library's API does not
  change.
- A caller's `Io` covers only the moved calls. It cannot fake the shell's whole
  file system: `stat`, redirections and script input stay direct. The API
  documentation must say this.
- The forked child keeps using the caller's `Io`. That is safe with
  `Io.Threaded.init_single_threaded`, which `sh` uses; an embedding program must
  pass an `Io` that is safe after `fork`.
- `docs/std-io-gaps.md` needs correcting: Zig 0.17.1 can change and read the
  current directory by path (row 22), and `File.setOwner` works (row 3).
