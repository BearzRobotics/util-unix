# Benchmarks against the GNU originals

`sh bench/run.sh [util ...]` builds the project (ReleaseFast, stripped) into a
scratch directory, generates input data, and runs
[poop](https://github.com/andrewrk/poop) on every case in `bench/cases.txt`,
comparing `/usr/bin/<util>` (GNU, the reference used by `test/testlib.sh`)
with our binary. It prints a markdown table of ratios (ours / GNU; below 1.00
is better for us) for wall time, CPU cycles, instructions and peak RSS, plus
the stripped binary sizes.

Environment: `POOP` (path to poop; default `../poop/zig-out/bin/poop`),
`WORK` (scratch directory), `DURATION` (ms per command, default 1000), `OPT`
(optimize mode, default ReleaseFast), `LC_ALL=C` is set for both sides.

Notes for reading results:

- poop splits a command on spaces without quoting, so arguments cannot
  contain spaces.
- The chown/chgrp cases change a tree to the owner it already has, so no
  privileges are needed and the file system state is identical for both sides;
  what is measured is the traversal plus one fchownat per file.
- getent reads the system files only, while glibc's goes through NSS
  (nsswitch.conf, shared libraries, systemd); the ratios show that cost, not
  equal work.
- Wall time on WSL2 is noisy (swings of 2x between runs were seen); cycles and
  instructions are steadier. Treat wall-time ratios within about 20% as noise.
- Ratios say nothing about correctness; see `test/`.
