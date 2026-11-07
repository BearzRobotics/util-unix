# groups: compatibility record

Status: implemented; 15 differential cases pass against GNU groups 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- GNU coreutils 9.7 manual, node "groups invocation", and `groups --help`.
- POSIX.1-2024 no longer specifies `groups`; it is a GNU/BSD command (not re-checked in this session).
- Behaviour was verified by running both binaries (`sh test/test_groups.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| Everything | GNU |

## Supported

Same data as `id -Gn`. Differential-tested for the invoking user, system users, a missing user, two users, and error paths.

## Deliberate deviations and gaps

The gaps of `docs/compatibility/id.md` apply (files-only lookup). The many-groups case is covered by the VM test described there. A numeric USERNAME is not looked up as a uid (unlike id).

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files. Built with `-Dtarget=x86_64-linux-musl`, the
unit tests and the full differential suite (748 cases) pass on a glibc host
(2026-11-07); a run on a real musl distribution has not been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
