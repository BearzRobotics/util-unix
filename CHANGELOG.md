# Changelog

## Unreleased

**Added**
- `sh`: a POSIX shell (decision 0009, milestone 1: lexer, parser, all expansions, redirections and
  here-documents, control flow, functions, subshells, traps, special and regular builtins) as the
  library `util_unix.sh` plus the `sh` wrapper. Diagnostics have stable codes (SH1001-SH7009), four
  styles (`--diagnostics=posix|rich|json|gcc`), `sh --explain CODE`, and `sh --check` lint mode.
  Differential suite `test/test_sh.sh` (dash, bash --posix, busybox ash, yash, FreeBSD sh),
  `test/test_sh_diag.sh`, `test/test_sh_lint.sh`; `docs/std-io-gaps.md` rows 17-24; `sys.zig` is now
  part of the library module.
- `--json` for `uname`, `id` and `who` (not GNU; decision 0007) and `util_unix.json`.

## 0.3.0

Six more commands (decision 0006, which lifts the SPEC rule against
commands that util-linux or procps also ship, for these names).

**Added**
- `hostname` (Debian `hostname` 3.25; 38 differential cases), `who` (GNU
  coreutils 9.7; 89), `pinky` (GNU 9.7; 32 long-format cases against GNU plus 7
  golden short-format cases), `stty` (GNU 9.7; 670, most on a pseudo-terminal),
  `chcon` (GNU 9.7; 54) and `runcon` (GNU 9.7; 26 on a kernel without SELinux).
- Library modules `hostname`, `utmp`, `localtime`, `who`, `pinky`,
  `stty`, `selinux` and `chcon`; `Uname.domainname()` in `proc`.
- Manpages and compatibility records for all six.
- Decision 0006. SPEC.md moves to Draft 0.3 for the amended §1, §4.1 and §13.

**Known gaps**
- `who` and `pinky` read `/var/run/utmp`, not systemd-logind.
- `pinky`'s short format and `runcon`'s transition could not be compared with
  GNU on the development machine (see their compatibility records).
- `stty` error text differs from GNU for a few requests a pseudo-terminal
  ignores (parity, character size); `hostname -A/-I` and `runcon -c` are not
  supported.
- No benchmarks or QEMU tests were added for the six.

## 0.2.0

Moves the Unix-only commands into util-unix (decision 0005) and releases the
split-free library.

**Added**
- `chmod`, `id`, `groups`, `tty` and `uname`, each as a library module in
  `util_unix` plus a thin wrapper, tested against GNU coreutils 9.7 (278, 190,
  15, 9 and 34 differential cases).
- Manpages (`docs/manpages/`) and compatibility records
  (`docs/compatibility/`) for all eight commands.
- `test/vm/run.sh`: a QEMU guest with only busybox and these binaries, run as
  root, covering a real terminal for `tty`, privileged `chown`/`chgrp`/`chmod`,
  and `id`/`groups` in a process with 1503 groups.
- Benchmarks against GNU with poop (`docs/benchmarks/2026-11-07.md`).
- Decisions 0004 (files-only account lookup) and 0005 (Unix-only commands
  belong here).
- GPL-2.0-or-later: `LICENSE`, SPDX headers, license sections in the manpages.

**Changed**
- `--version` is read from `build.zig.zon`.
- `quotef`/`quoteaf` follow GNU's quoting more closely (`"it's"`, runs of
  control characters).

**Fixed**
- `id` and `groups` printed only the primary group for a process with more than
  1024 supplementary groups.

**Removed**
- `split`: portable, owned by Core Utils.

## 0.1.0

First tagged release: `split`, `chown`, `chgrp` and `getent`, the
`util_unix` library, the multicall executable.
