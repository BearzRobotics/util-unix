# Changelog

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
