# chmod: compatibility record

Status: implemented; 278 differential cases pass against GNU chmod 9.7 in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0005.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `chmod`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html (cited; the page was not re-read when this record was written, so the table below follows the GNU manual and marks only what is certain).
- GNU coreutils 9.7 manual, node "chmod invocation" (`info '(coreutils) chmod invocation'`) and `chmod --help`, as installed on the development machine (`chmod (GNU coreutils) 9.7`).
- Behaviour was verified by running both binaries (`sh test/test_chmod.sh`),
  not by reading alone. The upstream source of the reference implementation was
  not consulted for this record; the implementation is independent.

## What is POSIX and what is an extension

| Feature | Source |
|---|---|
| MODE operand (octal, symbolic `[ugoa][-+=][rwxXst]`, comma lists), `-R` | POSIX |
| `-c`, `-f`, `-v`, `-h`/`--no-dereference`, `--dereference`, `--reference`, `--preserve-root`, `--no-preserve-root`, `-H`, `-L`, `-P`, long-option abbreviation, options after operands | GNU manual; whether POSIX.1-2024 also specifies `-H`/`-L`/`-P` was not checked |

## Supported

All options of GNU chmod 9.7. Differential-tested: octal and symbolic modes (including `X`, `s`, `t`, copy-from-class `u`/`g`/`o`), umask interplay for five umasks, `-c`/`-v`/`-f`, `--reference`, `-R` with `-H`/`-L`/`-P`/`-h`, dangling and directory links, `--preserve-root`, mode-looking words such as `-w` taken as MODE, and GNU's quoting of names with spaces and quotes.

## Deliberate deviations and gaps

1. **No SELinux, ACL or xattr handling.** Only the mode bits are set.
2. **`read_failed` wording.** If reading a directory fails part-way, we print `chmod: fts_read failed: CAUSE`. The exact GNU wording was not verified and no test covers it.
3. **Unchanged modes.** We always call the set-permissions operation, even when the new mode equals the old one. The inherited comment claiming GNU does the same was not checked against GNU's source.
4. **Umask is read once at start-up** by setting it to 0 and restoring it (the syscall has no query form). A concurrent file creation by another thread in that instant would see the wrong mask; chmod is single-threaded.
5. **`-h` on a symbolic link** is silently skipped; Linux cannot change a link's own mode. (GNU behaves the same in the tested cases.)

## Platforms

Linux only so far (tested on 6.18, WSL2, against the reference binary named
above). The executable is static and does not link libc, so musl and glibc
differ only in the host's account files; no musl-specific run has been made.
Other Unix-like systems are not supported: `proc.zig` and `fsown.zig` return
neutral values or `error.Unsupported` there (decision 0003).
