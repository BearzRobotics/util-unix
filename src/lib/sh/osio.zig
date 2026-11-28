// SPDX-License-Identifier: GPL-2.0-or-later
//! The shell's system access that goes through `std.Io` (decision 0011; what
//! cannot is in `sys.zig`, with the reasons in that record).
//!
//! Where a caller reports a failure, the `std.Io` error is turned back into
//! the system's error number, so `sys.errno()` and `sys.strerror()` work as
//! they do after a direct call.

const std = @import("std");
const Io = std.Io;
const sys = @import("../../sys.zig");

/// access(2) with the real ids.
pub fn access(io: Io, path: []const u8, mode: Io.Dir.AccessOptions) bool {
    Io.Dir.cwd().access(io, path, mode) catch return false;
    return true;
}

pub fn isatty(io: Io, fd: i32) bool {
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.isTty(io) catch false;
}

/// False if the directory cannot be entered.
pub fn chdir(io: Io, path: []const u8) bool {
    std.process.setCurrentPath(io, path) catch return false;
    return true;
}

/// The current directory as the kernel knows it, written into `buf`.
pub fn getcwd(io: Io, buf: []u8) sys.Error![]const u8 {
    const n = std.process.currentPath(io, buf) catch |e| return fail(e);
    return buf[0..n];
}

/// rename(2): `new` is replaced in one step.
pub fn rename(io: Io, old: []const u8, new: []const u8) sys.Error!void {
    const cwd = Io.Dir.cwd();
    Io.Dir.rename(cwd, old, cwd, new, io) catch |e| return fail(e);
}

/// Remove a file the shell made; there is nothing to do if that fails.
pub fn unlink(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// The text of the symbolic link `path`, written into `buf`.
pub fn readlink(io: Io, path: []const u8, buf: []u8) sys.Error![]const u8 {
    const n = Io.Dir.cwd().readLink(io, path, buf) catch |e| return fail(e);
    return buf[0..n];
}

/// For names that must not repeat. `randomSecure` and not `random`: that one
/// seeds a generator once, which `fork` would copy to the child.
pub fn random32(io: Io) u32 {
    var v: u32 = 0;
    io.randomSecure(std.mem.asBytes(&v)) catch {
        const now = Io.Clock.now(.awake, io).nanoseconds;
        return @truncate(@as(u96, @bitCast(now)));
    };
    return v;
}

fn fail(e: anyerror) sys.Error {
    return sys.setErrno(errnoOf(e));
}

/// The Linux error number behind a `std.Io` error; 0 ("Unknown error") for one
/// it does not name.
fn errnoOf(e: anyerror) u16 {
    return switch (e) {
        error.PermissionDenied => 1,
        error.FileNotFound, error.CurrentDirUnlinked => 2,
        error.InputOutput, error.FileSystem, error.HardwareFailure => 5,
        error.SystemResources => 12,
        error.AccessDenied => 13,
        error.FileBusy => 16,
        error.CrossDevice => 18,
        error.NotDir => 20,
        error.IsDir => 21,
        error.NotLink => 22,
        error.NoSpaceLeft => 28,
        error.ReadOnlyFileSystem => 30,
        error.LinkQuotaExceeded => 31,
        error.NameTooLong, error.PathExceedsLimit => 36,
        error.DirNotEmpty => 39,
        error.SymLinkLoop => 40,
        error.DiskQuota => 122,
        else => 0,
    };
}

test "errors keep their system messages" {
    var st: Io.Threaded = .init_single_threaded;
    const io = st.io();
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.Sys, readlink(io, "/nonexistent/x", &buf));
    try std.testing.expectEqualStrings("No such file or directory", sys.strerror(sys.errno()));
    try std.testing.expectError(error.Sys, readlink(io, "/", &buf));
    try std.testing.expectEqualStrings("Invalid argument", sys.strerror(sys.errno()));
    try std.testing.expectError(error.Sys, rename(io, "/nonexistent/x", "/nonexistent/y"));
    try std.testing.expectEqualStrings("No such file or directory", sys.strerror(sys.errno()));
    try std.testing.expect(!isatty(io, 999));
    try std.testing.expect(!isatty(io, -1));
    try std.testing.expect(!access(io, "", .{}));
    try std.testing.expect(access(io, "/", .{ .execute = true }));
}
