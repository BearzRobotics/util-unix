# Architecture

Describes what is implemented now (not the target in `ai/SPECS.md`). Update it
with every structural change.

- Toolchain: Zig 0.17.1; standard-library APIs were checked against
  `~/.zvm/0.17.1/lib/std`.
- Commands implemented: `split` (decision 0001 for its ownership).
- Shape: a reusable library module, `util_unix`, plus thin command wrappers
  (decision 0002). DKDE and other Zig projects import the module; the
  executables are just one client of it.

## Layout

```
build.zig            exports module "util_unix"; per-command exes, multicall exe, tests
build.zig.zon        package: name util_unix, no dependencies
src/
  root.zig           the library's public surface: `pub const split = ...`
  lib/
    split.zig        split: Options/Mode, Namer (file-name generator), planSuffix,
                     parseSize, Diagnostic, run(); all splitting logic.
                     Imports only std.
  cli.zig            wrapper-side: Context, getopt-style matching, warn, errText,
                     quotef/quoteaf (GNU C-locale quoting)
  sys.zig            wrapper-side: the only std.posix use (SIGPIPE)
  commands.zig       registry: `all` + `modules` + get/find
  commands/split.zig option parsing, GNU validation order, diagnostics -> run()
  exe.zig            entry of an individual executable (command fixed by build option)
  multicall.zig      entry of `util-unix`: argv[0] link name, else `util-unix <cmd>`
  test_all.zig       unit-test root for the wrapper side
test/                differential shell tests against GNU (testlib.sh, test_split.sh,
                     run_all_tests.sh); OURS_MULTICALL=1 for multicall mode
bench/               poop comparison against the GNU binaries (README.md, run.sh)
docs/                this file, decisions/, compatibility/, manpages/, benchmarks/
```

## Data flow

```
 argv ──► commands/split.zig ──► util_unix.split.Options ──► split.run(io, gpa, opts, input, stdout, &diag)
          (parse, validate,                                     │   │            │
           GNU order)                                           │   │            └─ Observer: --verbose lines
                                                                │   └─ files via Io.Dir, filters via std.process.spawn
          exit status ◄── report(Diagnostic) ◄──────────────────┘
```

Inside `run`: `planSuffix` -> `Namer` -> one of `splitLines`, `splitBytes`,
`splitLineBytes`, `splitLineChunks`, `extractBytes`, `roundRobin`,
`extractRoundRobin` (all methods of the internal `Splitter`). Output goes
through `OutFile`, which owns a descriptor or a filter child and a write-behind
buffer.

## Memory and resources

- Library scratch memory comes from the caller's allocator and is freed before
  `run` returns: a 128 KiB read buffer, a 64 KiB stdout buffer, a 64 KiB
  write-behind buffer for the current file.
- `-C` holds at most one record (up to SIZE bytes) while deciding where it goes.
- `-n r/N` keeps N names and up to 4 MiB of per-file buffers in total; when
  descriptors run out it closes other files and reopens them for appending
  (positional writes at the recorded offset).
- `-n` modes on non-regular input hold the whole input in memory, capped at
  `max_spool_bytes` (default 1 GiB).
- Failures after partial output leave the files in place (POSIX).

## Build

- `zig build` installs one executable per command plus `util-unix`.
- `-Dcommands=a,b` restricts the set; unknown names fail the build.
- Adding a command: `src/lib/<name>.zig` (+ line in `root.zig`),
  `src/commands/<name>.zig`, then the name in `all` and `modules` in `commands.zig`.
- Binary sizes: `split` 312 KB stripped ReleaseFast, 190 KB ReleaseSmall (std's
  `Io` runtime is the floor, as in Core Utils); no libc is linked.
