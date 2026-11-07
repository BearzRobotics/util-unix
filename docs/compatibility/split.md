# split: compatibility record

Status: implemented; differential tests (164 cases) pass against GNU split 9.7
in individual and multicall mode. Date: 2026-11-07. Ownership: decision 0001.

## References

- POSIX.1-2024 (IEEE Std 1003.1-2024), `split`, consulted 2026-11-07:
  https://pubs.opengroup.org/onlinepubs/9799919799/utilities/split.html
- GNU coreutils 9.7, manual node "split invocation"
  (`info '(coreutils) split invocation'`) and `split --help`, as installed on
  the development machine (Ubuntu `coreutils-from-gnu`, `split (GNU coreutils) 9.7`).
- GNU coreutils 9.7 `src/split.c`, read from
  https://raw.githubusercontent.com/coreutils/coreutils/v9.7/src/split.c on
  2026-11-07 to settle behaviour the manual leaves open: suffix widening,
  `-n` chunk arithmetic, option-validation order, diagnostic wording. The
  implementation is independent; the file is GPL and was not copied.
- Behaviour was verified by running both binaries (`sh test/test_split.sh`), not
  by reading alone.

## What is POSIX and what is GNU

| Feature | Source |
|---|---|
| `-l N`, `-b N[k\|m]`, `-a N`, operands `file` `name`, default 1000 lines, default prefix `x`, `-` or no file = stdin, empty input creates no file, files already created are not deleted on suffix exhaustion | POSIX |
| Obsolete `-NUM` | accepted by GNU; POSIX.1-2024 dropped it |
| `-C`, `-n`, `-d`/`--numeric-suffixes[=FROM]`, `-x`/`--hex-suffixes[=FROM]`, `--additional-suffix`, `-e`, `-t`, `-u`, `--filter`, `--verbose`, size suffixes beyond `k`/`m` (`b`, `K`, `KB`, `KiB`, ... `Q`), automatic suffix widening, long options with abbreviation, options after operands | GNU extensions |

## Supported

All options of GNU split 9.7 except the undocumented `--io-blksize`. Notable
semantics (all differential-tested):

- Suffix widening `xyz` -> `xzaaa` -> ... when no `-a`, `-n` or start value is
  given; explicit `-a`, `-n` and `--numeric-suffixes=FROM` disable it.
- `-n N` (byte chunks, early files one byte longer), `-n K/N`, `-n l/N`,
  `-n l/K/N`, `-n r/N`, `-n r/K/N`; empty chunk files created unless `-e`.
- `-C` packs whole records; a record longer than SIZE starts a fresh file and
  is cut into SIZE-byte pieces.
- Output files are created with mode 0666 & ~umask; an existing output is
  truncated, but not if it is the input file ("would overwrite input; aborting").
- `--filter`: runs `$SHELL -c COMMAND` (default `/bin/sh`) per piece with
  `$FILE` set; the filter's exit status or fatal signal becomes ours; EPIPE
  from a filter that stopped reading is ignored.
- Diagnostics and exit status match GNU in the C locale (`LC_ALL=C`), including
  the `Try 'split --help'` lines, quoting of file names, and the ambiguous-option
  message listing possibilities.

## Deliberate deviations and gaps

1. **`--hex-suffixes=FROM` with letters.** GNU 9.7 computes the starting digit as
   `c - '0'`, so `--hex-suffixes=a -l1` produces `x0a x0e x10 x11 ...` (verified).
   We produce `x0a x0b x0c x0d x0e x0f x10 ...`. Not differential-tested.
2. **Non-seekable input for `-n N`, `-n K/N`, `-n l/N`, `-n l/K/N`.** GNU copies
   the input to a temporary file; we hold it in memory, up to
   `Options.max_spool_bytes` (1 GiB), then fail with `cannot determine file size`.
   Regular files are read in place with positional reads. `r/` modes stream.
3. **Starting offset.** GNU measures a regular-file standard input from its
   current offset; we always measure from 0. (`(head -c5; split -n2) < file` differs.)
4. **Overwrite-input check** compares inode numbers only (`File.Stat` has no
   device) and only when the input is a regular file. A false alarm needs an
   identically numbered inode on another file system.
5. **Close errors** are not detected: `std.Io.File.close` returns nothing.
6. **Early exit when every filter is dead.** GNU stops reading in `-b`/`-n r/N`
   once no filter accepts input; we keep reading to end of input.
7. **SIGPIPE in filters.** GNU resets SIGPIPE to the default in the child before
   `exec` when it was the default for the parent. `std.process.spawn` has no hook
   for that, so a filter inherits SIGPIPE ignored while `--filter` is used.
8. **Quoting** of file names in messages follows GNU's C-locale shell style for the
   cases tested (spaces, quotes, newlines); exotic names (non-ASCII, `=`/`%`
   positions) were not compared.
9. **Locale.** No message translation; multibyte separators are rejected as in GNU.
10. **No file-name length pre-check** (POSIX requires failing before creating any
    file when the name exceeds NAME_MAX): we rely on the first `create` failing
    with `File name too long`, which happens before any file exists (tested).
11. `--help` text is GNU's, minus the trailing bug-report/URL lines.

## Platforms

Built and run on Linux x86_64 (Zig 0.17.1, no libc linked; `-Dtarget=x86_64-linux-musl`
and `-Dtarget=x86_64-linux-gnu` binaries ran and split a sample file correctly).
Cross-compiled without running: `aarch64-linux`, `x86_64-macos`. Windows is out of
scope (SPEC §6.2). The differential suite was run only on x86_64 Linux/WSL2
against GNU 9.7.

## Tests

- `src/lib/split.zig` unit tests: file-name generator (widening, hex, numeric
  start, exhaustion), suffix planning, size parsing, and `run` end-to-end in a
  temporary directory (lines, bytes, `-C`, `-n`, `l/`, `r/`, refusal to overwrite the input).
- `src/commands/split.zig`, `src/cli.zig`: suffix-length parsing, quoting.
- `test/test_split.sh`: 164 differential cases (options, errors, filters, existing
  files, FIFO outputs, descriptor limit via `ulimit -n 16`, 18000+ file widening).
  `OURS_MULTICALL=1 sh test/test_split.sh` runs the same cases through
  `util-unix split`. Invocation by link name was checked by hand.
- Benchmarks: docs/benchmarks/2026-11-07.md.

## Not yet done

- Run on glibc-dynamic and musl-dynamic hosts (the binary links no libc).
- Privileged or destructive tests: none needed; tests only write below `mktemp -d`.
- Tests against GNU output of locale-dependent messages.
