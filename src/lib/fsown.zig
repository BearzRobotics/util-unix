// SPDX-License-Identifier: GPL-2.0-or-later
//! File ownership primitives that `std.Io` (Zig 0.17.1) lacks.
//!
//! Two gaps, checked 2026-11-07 against `~/.zvm/0.17.1/lib/std/Io`:
//!  - `File.Stat` has no uid, gid or device number, which ownership tools need.
//!    `statAt` / `statHandle` fill it from Linux `statx(2)`.
//!  - `Dir.setFileOwner` (fchownat) is declared but panics with "TODO implement
//!    dirSetFileOwner" in `Io.Threaded`. `chownAt` calls `fchownat(2)` directly:
//!    it also works on files we cannot open and on symbolic links themselves
//!    (lchown), which fd-based `File.setOwner` cannot do.
//!
//! This module and `ownership.zig`'s use of it are the library's only
//! `std.os.linux` dependency (decision 0003). On other systems every call fails
//! with `error.Unsupported`.
//!
//! References: statx(2), fchownat(2), Linux man-pages.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Stat = struct {
    /// st_mode: file type bits and permissions.
    mode: u32,
    uid: u32,
    gid: u32,
    /// Device and inode identify a file uniquely while it exists.
    dev: u64,
    ino: u64,

    pub const type_mask: u32 = 0o170000;

    pub fn isDir(s: Stat) bool {
        return s.mode & type_mask == 0o040000;
    }
    pub fn isReg(s: Stat) bool {
        return s.mode & type_mask == 0o100000;
    }
    pub fn isLink(s: Stat) bool {
        return s.mode & type_mask == 0o120000;
    }
    pub fn sameFile(a: Stat, b: Stat) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

pub const Error = error{
    Unsupported,
    FileNotFound,
    NotDir,
    AccessDenied,
    SymLinkLoop,
    NameTooLong,
    SystemResources,
    InputOutput,
    BadFileDescriptor,
    /// EPERM: "Operation not permitted" (std.Io uses the same name).
    PermissionDenied,
    ReadOnlyFileSystem,
    InvalidArgument,
    Unexpected,
};

const linux = std.os.linux;

fn toError(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .IO => error.InputOutput,
        .BADF => error.BadFileDescriptor,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

fn fromStatx(sx: linux.Statx) Stat {
    return .{
        .mode = sx.mode,
        .uid = sx.uid,
        .gid = sx.gid,
        .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor,
        .ino = sx.ino,
    };
}

const want: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true };

/// Status of `name` relative to `dir`. With `follow` false a final symbolic
/// link is described rather than followed (lstat).
pub fn statAt(dir: Io.Dir, name: []const u8, follow: bool) Error!Stat {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    var sx: linux.Statx = undefined;
    var flags: u32 = linux.AT.NO_AUTOMOUNT;
    if (!follow) flags |= linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(dir.handle, @ptrCast(&buf), flags, want, &sx);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return toError(e);
    return fromStatx(sx);
}

/// Status of an open file or directory (fstat).
pub fn statHandle(handle: std.posix.fd_t) Error!Stat {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(handle, "", linux.AT.EMPTY_PATH, want, &sx);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return toError(e);
    return fromStatx(sx);
}

/// fchownat(2): change owner and/or group (null leaves it alone) of `name`
/// relative to `dir`. With `follow` false a final symbolic link is changed
/// itself (lchown).
pub fn chownAt(dir: Io.Dir, name: []const u8, uid: ?u32, gid: ?u32, follow: bool) Error!void {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    // (uid_t)-1 / (gid_t)-1 mean "leave unchanged".
    const rc = linux.fchownat(dir.handle, @ptrCast(&buf), uid orelse std.math.maxInt(u32), gid orelse std.math.maxInt(u32), flags);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return toError(e);
}
