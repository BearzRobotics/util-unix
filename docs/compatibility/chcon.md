# chcon: compatibility record

Status: implemented; 59 differential cases and 2 race cases pass against GNU chcon 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0006.

## References

- GNU coreutils 9.7 manual, node "chcon invocation" and `chcon --help` (embedded as the program's help text), as installed (`chcon (GNU coreutils) 9.7`). chcon is not in POSIX.
- selinux(8), xattr(7), setxattr(2), Linux man-pages.
- Behaviour was verified by running both binaries on scratch directories and comparing output, messages, status and the `security.selinux` attribute of every file afterwards (`sh test/test_chcon.sh`). The upstream source of the reference implementation and libselinux were not consulted; the implementation is independent.

## Supported

`CONTEXT FILE...`, `-u -r -t -l` (component edits, applied to each file's current context), `--reference=RFILE`, `-R`, `-H -L -P`, `-h`/`--no-dereference`, `--dereference`, `-v`, `--preserve-root`/`--no-preserve-root`, and the diagnostics of each failure (unlabeled file, malformed existing context, bad component, missing file, `/`). A directory is changed after its contents, as GNU does.

## How it is tested

The host kernel has no SELinux, so `security.selinux` is an ordinary extended attribute; an unprivileged user may set it on a tmpfs in a user namespace of their own. GNU chcon (via libselinux) then also just stores the string, which is what is compared. Where the scratch directory refuses `security.*`, the suite runs itself on such a tmpfs, and is skipped only where that is impossible. The race cases need strace.

## Deliberate deviations and gaps

1. **Contexts are not validated against a policy.** A complete CONTEXT is stored as given; on an SELinux kernel the kernel accepts or refuses it, as for GNU. Behaviour under a loaded policy (including the kernel's refusal texts) was not run.
2. **The stored value ends with a NUL**, as libselinux writes it, so a file labelled by one program reads back correctly with the other (checked).
3. **A range that is set to an empty string leaves its colon** (`u:r:t:s0` with `-l ''` becomes `u:r:t:`), as GNU does.
4. **Attributes below the operand are set through `/proc/self/fd`** (Linux has no `*at` forms of the attribute calls before 6.13). Each entry is opened relative to its parent directory and checked to be the file that was examined, so a directory replaced during the walk cannot send a change elsewhere. A recursive run therefore needs /proc and refuses without it. The operand itself is used by its path.
5. **`--version`** prints `chcon (util-unix) VERSION`.

## Platforms

Linux only. The executable is static and does not link libc. Tested on x86-64 Linux 6.18 (WSL2), on a file system that accepts `security.*` attributes.
