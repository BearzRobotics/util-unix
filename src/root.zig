//! util_unix: reusable Unix utility logic as a Zig library.
//!
//! This module is the native API (ai/AGENTS.md §13). It contains no argument
//! parsing, no terminal output and no process-wide state: every operation takes
//! a `std.Io` and an allocator, reports results through return values, a
//! caller-supplied `Diagnostic` or an event callback, and leaves signal
//! dispositions and exit codes to the caller. The command-line executables in
//! `src/commands/` are thin wrappers over it.

pub const fsown = @import("lib/fsown.zig");
pub const userdb = @import("lib/userdb.zig");
pub const userspec = @import("lib/userspec.zig");
pub const ownership = @import("lib/ownership.zig");
pub const getent = @import("lib/getent.zig");

test {
    _ = fsown;
    _ = userdb;
    _ = userspec;
    _ = ownership;
    _ = getent;
}
