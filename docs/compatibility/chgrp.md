# chgrp: compatibility record

Status: implemented; 81 differential cases pass against GNU chgrp 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `chgrp`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chgrp.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "chgrp invocation" (`info '(coreutils) chgrp invocation'`) and `chgrp --help`, as installed on the development machine (`chgrp (GNU coreutils) 9.7`).
- Behaviour was verified by running both binaries (`sh test/test_chgrp.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| `group`, `-R`, `-h`, `-H`, `-L`, `-P` | POSIX |
| `--from`, `--reference`, `-c`, `-f`, `-v`, `--preserve-root`, `--dereference` | GNU |

## Supported

The same engine as chown (`src/lib/ownership.zig`, wrapper `src/ownership_cli.zig`). Differential-tested like chown.

## Deliberate deviations and gaps

The same gaps as `docs/compatibility/chown.md`: files-only lookup, privileged changes lightly tested.

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files. Built with `-Dtarget=x86_64-linux-musl`, the
unit tests and the full differential suite (748 cases) pass on a glibc host
(2026-11-07); a run on a real musl distribution has not been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
