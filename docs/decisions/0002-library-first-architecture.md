# 0002: Library first, executables are wrappers

Status: accepted by the maintainer. Date: 2026-11-07

## Context

Request: "implement all core logic in a zig library and then have the
executables be wrappers. That way things like dkde can build against it."
ai/AGENTS.md §13 already asks for a native Zig module as the primary interface,
using the `std.Io` interface. Core Utils, by contrast, keeps its logic inside
`src/commands/<name>.zig`, entangled with argument parsing and diagnostics.

## Decision

- `src/root.zig` is the package module **`util_unix`**, exported from
  `build.zig` with `b.addModule("util_unix", ...)`. A dependent writes
  `b.dependency("util_unix", .{...}).module("util_unix")`.
- Each command has a library namespace under `src/lib/` (`util_unix.split`).
  It takes `std.Io` and an allocator, does no argument parsing, prints nothing,
  and changes no process-wide state (no signal dispositions, no exit calls,
  no environment writes). Results come back as values, failures as
  `error.Failed` plus a caller-owned `Diagnostic`, and progress through an
  optional `Observer` callback.
- `src/commands/<name>.zig` is the wrapper: it parses argv the way the
  reference implementation does, validates in the same order (so diagnostics
  match), calls the library, and formats the `Diagnostic`. `src/cli.zig` and
  `src/sys.zig` are wrapper-side only; the library does not import them.
- `exe.zig` (one binary per command) and `multicall.zig` (`util-unix <cmd>` or a
  link named after the command) are unchanged from the Core Utils design and
  call the same wrapper (SPEC §8).
- Tests: library unit tests in `src/lib/*.zig` run against `src/root.zig`
  alone (no wrapper code), wrapper tests via `src/test_all.zig`, behaviour
  tests via `test/test_<cmd>.sh` against GNU.

## Alternatives considered

- Library per command as separate packages: more build files, no benefit yet.
- C ABI export: optional under AGENTS.md §13; not needed by DKDE, so omitted.
  Nothing in the library prevents adding one later.

## Consequences

- The API is as stable as the maintainer makes it; it is pre-1.0 and may
  change. Anything exported from `root.zig` is intended for dependents.
- Callers using `Options.filter` must decide SIGPIPE handling themselves.
- The wrapper does more work than a pure "forward argv" shim: the argument
  grammar is part of the command's behaviour, so it stays out of the library.
