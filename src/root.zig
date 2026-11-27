// SPDX-License-Identifier: GPL-2.0-or-later
//! util_unix: reusable Unix utility logic as a Zig library.
//!
//! This module is the native API (ai/AGENTS.md §13). It contains no argument
//! parsing, no terminal output and no process-wide state: every operation takes
//! a `std.Io` and an allocator, reports results through return values, a
//! caller-supplied `Diagnostic` or an event callback, and leaves signal
//! dispositions and exit codes to the caller. The command-line executables in
//! `src/commands/` are thin wrappers over it.
//!
//! The exception is `sh`: a POSIX shell owns the process it runs in (see
//! `lib/sh.zig` and decision 0009).

pub const fsown = @import("lib/fsown.zig");
const treewalk = @import("lib/treewalk.zig");
pub const userdb = @import("lib/userdb.zig");
pub const userspec = @import("lib/userspec.zig");
pub const ownership = @import("lib/ownership.zig");
pub const getent = @import("lib/getent.zig");
pub const mode = @import("lib/mode.zig");
pub const proc = @import("lib/proc.zig");
pub const uname = @import("lib/uname.zig");
pub const tty = @import("lib/tty.zig");
pub const identity = @import("lib/identity.zig");
pub const chmod = @import("lib/chmod.zig");
pub const hostname = @import("lib/hostname.zig");
pub const localtime = @import("lib/localtime.zig");
pub const pinky = @import("lib/pinky.zig");
pub const chcon = @import("lib/chcon.zig");
pub const selinux = @import("lib/selinux.zig");
pub const stty = @import("lib/stty.zig");
pub const who = @import("lib/who.zig");
pub const utmp = @import("lib/utmp.zig");
pub const json = @import("lib/json.zig");
pub const sh = @import("lib/sh.zig");
/// Operating-system facilities `std.Io` lacks (docs/std-io-gaps.md).
pub const sys = @import("sys.zig");

test {
    _ = fsown;
    _ = treewalk;
    _ = userdb;
    _ = userspec;
    _ = ownership;
    _ = getent;
    _ = mode;
    _ = proc;
    _ = uname;
    _ = tty;
    _ = identity;
    _ = chmod;
    _ = hostname;
    _ = localtime;
    _ = pinky;
    _ = chcon;
    _ = selinux;
    _ = stty;
    _ = who;
    _ = utmp;
    _ = json;
    _ = sh;
}
