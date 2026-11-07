# tty: compatibility record

Status: implemented; 9 differential cases pass against GNU tty 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `tty`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tty.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "tty invocation" (`info '(coreutils) tty invocation'`) and `tty --help`, as installed on the development machine (`tty (GNU coreutils) 9.7`).
- ttyname(3), isatty(3).
- Behaviour was verified by running both binaries (`sh test/test_tty.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| `-s`, exit statuses 0/1 | POSIX |
| `--silent`, `--quiet`, exit 2 for usage and 3 for write errors | GNU |

## Supported

All options of GNU tty 9.7. The automated tests never have a terminal on standard input, so the terminal-present path (printing the device name) is covered by one unit test of the negative case only and has not been tested automatically.

## Deliberate deviations and gaps

1. **Terminal name through /proc.** The name comes from `/proc/self/fd/0`, not a ttyname(3) search of /dev. Without /proc a terminal is reported as "not a tty".
2. **The positive path is unverified by tests.** Run `tty` in a terminal and compare with GNU manually.

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files. Built with `-Dtarget=x86_64-linux-musl`, the
unit tests and the full differential suite (748 cases) pass on a glibc host
(2026-11-07); a run on a real musl distribution has not been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
