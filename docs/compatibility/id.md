# id: compatibility record

Status: implemented; 190 differential cases pass against GNU id 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `id`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/id.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "id invocation" (`info '(coreutils) id invocation'`) and `id --help`, as installed on the development machine (`id (GNU coreutils) 9.7`).
- getgroups(2), Linux man-pages.
- Behaviour was verified by running both binaries (`sh test/test_id.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| `-u`, `-g`, `-G`, `-n`, `-r`, default format | POSIX |
| `-z`/`--zero`, `-a` (ignored), `-Z`/`--context`, several USERs, numeric USER fallback, long options | GNU |

## Supported

All options of GNU id 9.7 except a working `-Z`. Differential-tested for the invoking user and a set of system users and ids: every format flag combination, error and warning paths, options after operands, and `--` handling.

## Deliberate deviations and gaps

1. **`-Z`/`--context` always fails** with GNU's message for a kernel without SELinux; no SELinux support exists.
2. **Files-only lookup** (decision 0004): an account known only to NSS sources appears as a bare number.
3. **At most 1024 supplementary groups** for the calling process. With more, getgroups(2) fails and none are printed. Not tested.
4. For a named USER, the group list is the primary group plus every group whose member list names the user, in file order (as getgrouplist does for the files backend).

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files. Built with `-Dtarget=x86_64-linux-musl`, the
unit tests and the full differential suite (748 cases) pass on a glibc host
(2026-11-07); a run on a real musl distribution has not been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
