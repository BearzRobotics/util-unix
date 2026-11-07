//! util_unix: reusable Unix utility logic as a Zig library.
//!
//! This module is the native API (ai/AGENTS.md §13). It contains no argument
//! parsing, no terminal output and no process-wide state: every operation takes
//! a `std.Io` and an allocator, reports results through return values and a
//! caller-supplied `Diagnostic`, and leaves signal dispositions and exit codes
//! to the caller. The command-line executables in `src/commands/` are thin
//! wrappers over it.

pub const split = @import("lib/split.zig");

test {
    _ = split;
}
