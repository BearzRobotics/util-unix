//! tty: the terminal connected to a file.
//!
//! References: POSIX.1-2024 tty
//! (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tty.html);
//! GNU coreutils 9.7 manual, "tty invocation"; isatty(3), ttyname(3).
//!
//! The name comes from the `/proc/self/fd/N` link, as glibc's ttyname does, so
//! it needs /proc (Linux). Without it the terminal has no name here.

const std = @import("std");
const Io = std.Io;

/// True when `file` refers to a terminal.
pub fn isTerminal(io: Io, file: Io.File) bool {
    return file.isTty(io) catch false;
}

/// Path of the terminal behind `file`, written into `buf`, or null when it is
/// not a terminal or its name cannot be found. The result borrows `buf`.
pub fn name(io: Io, file: Io.File, buf: []u8) ?[]const u8 {
    if (!isTerminal(io, file)) return null;
    var link: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&link, "/proc/self/fd/{d}", .{file.handle}) catch return null;
    const n = Io.Dir.readLinkAbsolute(io, path, buf) catch return null;
    return buf[0..n];
}

test "a regular file is not a terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(std.testing.io, "f", .{});
    defer f.close(std.testing.io);
    var buf: [128]u8 = undefined;
    try std.testing.expect(!isTerminal(std.testing.io, f));
    try std.testing.expect(name(std.testing.io, f, &buf) == null);
}
