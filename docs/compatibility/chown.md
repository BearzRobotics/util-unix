# chown: compatibility record

Status: implemented; 77 differential cases pass against GNU chown 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `chown`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chown.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "chown invocation" (`info '(coreutils) chown invocation'`) and `chown --help`, as installed on the development machine (`chown (GNU coreutils) 9.7`).
- `lib/userspec.c` behaviour from gnulib (the "." separator warning, "+N" numeric forms) as described in the library header; reproduced from observed behaviour, not copied.
- Behaviour was verified by running both binaries (`sh test/test_chown.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| `owner[:group]`, `-R`, `-h`, `-H`, `-L`, `-P` | POSIX |
| `--from`, `--reference`, `-c`, `-f`, `-v`, `--preserve-root`, `--no-preserve-root`, `--dereference`, `OWNER:` login-group form, `+N` numeric form, `.` as old separator (with warning) | GNU |

## Supported

Everything in `chown --help` of GNU 9.7. Differential-tested: owner/group/both/neither forms, numeric and symbolic ids, `--from`, `--reference`, recursion with `-H`/`-L`/`-P`, `-h` on links, `--preserve-root`, verbose and changes reporting. The tests run unprivileged: they cover changes to the invoking user and to groups that user belongs to, and the `Operation not permitted` failure paths (for example `chown root f`).

## Deliberate deviations and gaps

1. **Files-only account lookup** (decision 0004): users and groups defined only in LDAP, SSSD or systemd-userdb are reported as invalid.
2. **Privileged changes are lightly tested.** Tests run unprivileged, so a successful change of owner to a different account (which needs root) is not covered by the automated tests.
3. **`File.close` errors** cannot be reported (decision 0003).

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files; no musl-specific run has been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
