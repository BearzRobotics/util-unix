//! Read-only facts about the calling process and the machine that `std.Io`
//! (Zig 0.17.1) does not expose: credentials, the umask and `uname(2)`.
//!
//! Checked 2026-11-07 against `~/.zvm/0.17.1/lib/std/Io*`: there is no
//! credentials, umask or utsname API. These calls go straight to Linux
//! through `std.os.linux` (decision 0003). None of them changes process-wide
//! state except `umask`, which has no query form: it sets the mask to 0 and
//! restores it, so a thread creating files in that instant would see the
//! wrong mask. Callers read it once at start-up.
//!
//! On systems other than Linux these functions return neutral values (root
//! credentials, mask 022, "unknown" names): the library builds but does not
//! claim to work there (SPEC §6.2).
//!
//! References: getuid(2), getgroups(2), umask(2), uname(2), Linux man-pages.

const std = @import("std");
const builtin = @import("builtin");

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

/// Supplementary group ids of the calling process, in kernel order, written to
/// the front of `buf`. A process with more groups than `buf` holds gets an
/// empty result (getgroups fails with EINVAL); use a buffer of at least 65536
/// entries (the kernel limit, NGROUPS_MAX) when that matters.
pub fn supplementaryGroups(buf: []u32) []u32 {
    if (comptime !is_linux) return buf[0..0];
    const n = std.os.linux.getgroups(buf.len, @ptrCast(buf.ptr));
    if (@as(isize, @bitCast(n)) < 0) return buf[0..0];
    return buf[0..n];
}

/// The file-mode creation mask. See the file comment for the caveat.
pub fn umask() u16 {
    if (comptime !is_linux) return 0o022;
    const old = std.os.linux.syscall1(.umask, 0);
    _ = std.os.linux.syscall1(.umask, old);
    return @intCast(old & 0o7777);
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
};

pub fn uname() Uname {
    if (comptime !is_linux) return .{ .raw = {} };
    var u: Uname = .{ .raw = undefined };
    _ = std.os.linux.uname(&u.raw);
    return u;
}

test "identity, groups, umask and uname answer without failing" {
    const id = identity();
    _ = id;
    var buf: [256]u32 = undefined;
    _ = supplementaryGroups(&buf);
    try std.testing.expect(umask() <= 0o777);
    const u = uname();
    if (is_linux) try std.testing.expectEqualStrings("Linux", u.sysname());
}
