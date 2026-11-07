# uname: compatibility record

Status: implemented; 34 differential cases pass against GNU uname 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `uname`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/uname.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "uname invocation" (`info '(coreutils) uname invocation'`) and `uname --help`, as installed on the development machine (`uname (GNU coreutils) 9.7`).
- uname(2), Linux man-pages.
- Behaviour was verified by running both binaries (`sh test/test_uname.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| `-a -m -n -r -s -v` | POSIX |
| `-p`, `-i`, `-o`, long options | GNU |

## Supported

All options of GNU uname 9.7 on Linux. Differential-tested: every short and long option, combinations, `-a`, operand and unknown-option errors, ambiguous abbreviations.

## Deliberate deviations and gaps

1. **`-p` and `-i` print the machine name.** GNU 9.7 on this machine does the same; GNU's documentation says `-a` omits them when they are unknown; we never have an unknown value to omit. We always include them.
2. **`-o` prints "GNU/Linux"** on Linux (also on musl systems), as GNU does.
3. **Other systems** get "unknown" for every field.

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files; no musl-specific run has been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
