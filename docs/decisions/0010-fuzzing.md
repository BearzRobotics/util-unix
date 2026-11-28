# 0010: Fuzzing

Status: accepted by the maintainer. Date: 2026-11-19, updated 2026-11-20. Same rules as
util-core decision 0007, adapted. (The number is 0010 because 0009 is the shell.)

## Decision

Every library entry point that consumes untrusted bytes (passwd, group, shadow and
the other databases `getent` reads, utmp files, `-g` saved terminal state and
settings vectors, mode strings, OWNER:GROUP specs, hosts-file text, context
strings, time zone files) has a fuzz test under `src/fuzz/`, written as
`fn (ctx, *std.testing.Smith) !void` and run with `engine.fuzz`. `zig build test` runs
them as short regression tests; `zig build fuzz`, started through `tools/fuzz.sh`, is the
campaign. Library-first (decision 0002) is what makes this possible: a fuzz test calls
the library with generated options and input, with no process or terminal.

## Rules

- A fuzz test checks invariants, not output equality: no crash, no hang (bounded work),
  no leak, no out-of-bounds, and well-formed output (JSON output parses with
  `std.json`). Where a reference tool exists, its differential suite
  (`test/test_CMD.sh`) is the oracle and must keep its count.
- Fuzz tests never touch the machine: no real terminal is opened, the host name and
  the clock are never set, nothing is flushed. File-system tests work in
  `std.testing.tmpDir`, and ownership changes use only the caller's own ids.
- Seed corpora come from the differential suites and real-world inputs. A corpus entry
  is a `Smith` byte string; `src/fuzz/seed.zig` builds one from text (the
  length-prefixed form `Smith.slice` reads).
- A crash or hang found is fixed in the library, the input that found it is added to
  the corpus, and the fix must keep the command's differential suite at its count.
- One file per area: userdb, getent, utmp (also `who`), pinky, stty, mode (also chmod),
  userspec, ownership (also fsown), identity, system (uname, hostname, localtime),
  selinux (also chcon), json, sh.

## Update 2026-11-20: our own engine, memory caps and the session-killing incident

- **Zig 0.17.1's built-in fuzzer does not run in this environment.** A 20-line project
  reproduces it: `zig build test --fuzz` reports "corrupted coverage file ... pcs_len was
  zero" without `.fuzz = true`, and with it the instrumented binary segfaults in
  `fuzzer_start_test`. Never pass `--fuzz`. Until that is fixed upstream, targets are
  driven by `src/fuzz/engine.zig` (a mutation engine with corpus, splicing, a dictionary
  of troublesome tokens, deterministic seeds). Targets keep the standard shape, so only
  the call `std.testing.fuzz` became `engine.fuzz`. The engine is not coverage-guided:
  seed corpora matter.
- **Memory is capped.** Every target allocates only from `limits.Capped` (64 MiB of live
  bytes, forwarding to `std.testing.allocator` so leaks still fail; `seed.capped` wraps a
  target). `error.OutOfMemory` from the cap is a valid outcome; an input that makes a
  library ask for hundreds of megabytes is a bug to fix (bound it, or refuse with a clear
  error, decision 0008).
- **Campaigns run only through `tools/fuzz.sh`**, which starts `zig build fuzz` in a
  transient systemd scope with `MemoryMax` and `RuntimeMaxSec`; hitting either kills every
  process in the scope. Never run a campaign binary directly and never leave one running:
  `timeout` on `zig build` does not kill the test binary it started.
- **Why:** on 2026-11-19 and 2026-11-20 a Zig test binary named `test` grew to 20 and
  23 GB, the kernel's out-of-memory kill took it, and systemd then killed the whole
  terminal scope, including the Claude Code session and its agents.
- A crash or hang cannot be caught in-process: before each run the input is written to
  `$FUZZ_CURRENT`, which is the reproducer; a returned error saves the input to
  `$FUZZ_FINDINGS`.

## Update 2026-11-28: brought onto the main line

- The work from the `fuzzing` branch was copied here and updated to the current library
  API; the branch is gone.
- `zig build test` runs the targets through `test/contain.sh`, so they have a memory limit
  there too.
- A test of the engine itself no longer removes `./fuzz-findings`, where campaigns save
  failing inputs.
- On the development machine under load, 2000 iterations per target took about 3 minutes
  (debug build). The default 20000 does not fit the default `FUZZ_SECONDS=600`; raise it,
  or lower the iteration count.
