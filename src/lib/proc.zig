// SPDX-License-Identifier: GPL-2.0-or-later
//! Read-only facts about the calling process and the machine that `std.Io`
//! (Zig 0.17.1) does not expose: credentials, the umask and `uname(2)`.
//!
//! Checked 2026-11-07 against `~/.zvm/0.17.1/lib/std/Io*`: there is no
//! credentials, umask or utsname API. These calls go straight to Linux
//! through `std.os.linux` (decision 0003). None of them changes process-wide
//! state, with one exception: umask(2) has no query form, so `umask` reads
//! /proc, and only where that fails sets the mask to 0 and restores it.
//!
//! On systems other than Linux these functions return neutral values (root
//! credentials, mask 022, "unknown" names): the library builds but does not
//! claim to work there (SPEC §6.2).
//!
//! References: getuid(2), getgroups(2), umask(2), uname(2), Linux man-pages.

const std = @import("std");
const builtin = @import("builtin");
const num = @import("num.zig");

const is_linux = builtin.os.tag == .linux;

pub const Identity = struct { uid: u32, euid: u32, gid: u32, egid: u32 };

pub fn identity() Identity {
    if (comptime !is_linux) return .{ .uid = 0, .euid = 0, .gid = 0, .egid = 0 };
    return .{
        .uid = std.os.linux.getuid(),
        .euid = std.os.linux.geteuid(),
        .gid = std.os.linux.getgid(),
        .egid = std.os.linux.getegid(),
    };
}

/// Supplementary group ids of the calling process, in kernel order. The
/// caller frees the result with `gpa`. getgroups(2) is asked for the count
/// first, so any number of groups up to the kernel limit (65536) works; if the
/// set grows between the two calls the query is repeated.
pub fn supplementaryGroups(gpa: std.mem.Allocator) error{ OutOfMemory, Unexpected }![]u32 {
    if (comptime !is_linux) return gpa.alloc(u32, 0);
    while (true) {
        const count = std.os.linux.getgroups(0, null);
        if (std.os.linux.errno(count) != .SUCCESS) return error.Unexpected;
        const buf = try gpa.alloc(u32, count);
        errdefer gpa.free(buf);
        const n = std.os.linux.getgroups(buf.len, @ptrCast(buf.ptr));
        switch (std.os.linux.errno(n)) {
            .SUCCESS => {
                if (n == buf.len) return buf;
                // Fewer groups than counted: hand back an exactly sized slice
                // so the caller's free() matches the allocation.
                defer gpa.free(buf);
                return gpa.dupe(u32, buf[0..n]);
            },
            .INVAL => {
                // The set grew since the count was taken; try again.
                gpa.free(buf);
                continue;
            },
            else => return error.Unexpected,
        }
    }
}

/// The file-mode creation mask. It is read from /proc (Linux 4.7), which
/// changes nothing. Without that, the only way is to set the mask to 0 and
/// back: a file another thread creates in that instant gets no mask, and two
/// such calls at once can leave it 0.
pub fn umask() u16 {
    if (comptime !is_linux) return 0o022;
    if (umaskFromProc()) |mask| return mask;
    const old = std.os.linux.syscall1(.umask, 0);
    _ = std.os.linux.syscall1(.umask, old);
    return @intCast(old & 0o7777);
}

fn umaskFromProc() ?u16 {
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, "/proc/thread-self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    // "Umask:" is among the first lines
    var buf: [512]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return parseUmask(buf[0..n]);
}

fn parseUmask(status: []const u8) ?u16 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Umask:")) continue;
        const value = std.mem.trim(u8, line["Umask:".len..], " \t");
        return num.parseInt(u16, value, 8) catch null;
    }
    return null;
}

test "the umask line of /proc status" {
    try std.testing.expectEqual(@as(?u16, 0o27), parseUmask("Name:\tsh\nUmask:\t0027\nState:\tR\n"));
    try std.testing.expectEqual(@as(?u16, null), parseUmask("Name:\tUmask:\n"));
    if (is_linux) {
        const old = std.os.linux.syscall1(.umask, 0o31);
        defer _ = std.os.linux.syscall1(.umask, old);
        try std.testing.expectEqual(@as(?u16, 0o31), umaskFromProc());
    }
}

/// Result of uname(2). The accessors return slices into this value, so keep
/// it where it is (do not copy it and keep an old slice).
pub const Uname = struct {
    raw: if (is_linux) std.os.linux.utsname else void,

    fn field(u: *const Uname, comptime name: []const u8) []const u8 {
        if (comptime !is_linux) return "unknown";
        return std.mem.sliceTo(&@field(u.raw, name), 0);
    }

    pub fn sysname(u: *const Uname) []const u8 {
        return u.field("sysname");
    }
    pub fn nodename(u: *const Uname) []const u8 {
        return u.field("nodename");
    }
    pub fn release(u: *const Uname) []const u8 {
        return u.field("release");
    }
    pub fn version(u: *const Uname) []const u8 {
        return u.field("version");
    }
    pub fn machine(u: *const Uname) []const u8 {
        return u.field("machine");
    }
    /// The NIS domain name ("(none)" when unset).
    pub fn domainname(u: *const Uname) []const u8 {
        if (comptime !is_linux) return "(none)";
        return u.field("domainname");
    }
};

/// `error.Unexpected` when the system call fails (a sandbox may forbid it).
pub fn uname() error{Unexpected}!Uname {
    if (comptime !is_linux) return .{ .raw = {} };
    var u: Uname = .{ .raw = undefined };
    if (std.os.linux.errno(std.os.linux.uname(&u.raw)) != .SUCCESS) return error.Unexpected;
    return u;
}

test "identity, groups, umask and uname answer without failing" {
    const id = identity();
    _ = id;
    const groups = try supplementaryGroups(std.testing.allocator);
    defer std.testing.allocator.free(groups);
    try std.testing.expect(umask() <= 0o777);
    const u = try uname();
    if (is_linux) try std.testing.expectEqualStrings("Linux", u.sysname());
}
