// SPDX-License-Identifier: GPL-2.0-or-later
//! SELinux security contexts: the text form, the extended attribute that holds a
//! file's context, and the per-process context files. The engine behind chcon
//! and runcon.
//!
//! References: selinux(8); xattr(7), setxattr(2), getxattr(2); proc_pid_attr(5),
//! Linux man-pages; GNU coreutils 9.7 manual, "chcon invocation" and "runcon
//! invocation". libselinux was not used or consulted: its documented behaviour
//! (contexts are `user:role:type[:range]`, `security.selinux` holds the text with
//! a terminating NUL) is reimplemented here.
//!
//! No policy knowledge is built in. A context string is only checked for shape
//! here; whether it is valid in the loaded policy is decided by the kernel when
//! it is stored (or, on a kernel without SELinux, not at all: the attribute is
//! then an ordinary extended attribute on file systems that allow `security.*`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const is_linux = builtin.os.tag == .linux;

/// The extended attribute that stores a file's context.
pub const xattr_name = "security.selinux";

pub const Components = struct {
    user: ?[]const u8 = null,
    role: ?[]const u8 = null,
    type: ?[]const u8 = null,
    range: ?[]const u8 = null,

    pub fn any(c: Components) bool {
        return c.user != null or c.role != null or c.type != null or c.range != null;
    }
};

pub const Which = enum { user, role, type, range };

pub const EditError = error{
    /// The existing context does not have the `user:role:type[:range]` shape.
    BadContext,
    /// A new component is not acceptable (contains ':' or a control character).
    BadComponent,
    OutOfMemory,
};

/// The component that made `edit` fail with `error.BadComponent`.
pub const Edit = struct {
    bad: ?Which = null,
};

/// Replace the given components of `context` and return the new text (owned by
/// the caller, allocated with `gpa`). A context needs at least user, role and
/// type; everything after the third colon is the range. A new user, role or
/// type may not contain ':'; a range may.
pub fn edit(gpa: Allocator, context: []const u8, c: Components, diag: *Edit) EditError![]u8 {
    var it = std.mem.splitScalar(u8, context, ':');
    var user = it.next() orelse return error.BadContext;
    var role = it.next() orelse return error.BadContext;
    var typ = it.next() orelse return error.BadContext;
    const had_range = it.index != null;
    var range: []const u8 = if (it.index) |idx| context[idx..] else "";
    if (user.len == 0 and role.len == 0 and typ.len == 0 and context.len == 0) return error.BadContext;

    const checks = [_]struct { v: ?[]const u8, which: Which, colon_ok: bool }{
        .{ .v = c.user, .which = .user, .colon_ok = false },
        .{ .v = c.role, .which = .role, .colon_ok = false },
        .{ .v = c.type, .which = .type, .colon_ok = false },
        .{ .v = c.range, .which = .range, .colon_ok = true },
    };
    for (checks) |chk| {
        const v = chk.v orelse continue;
        for (v) |ch| {
            if (ch < 0x20 or ch == 0x7f or (ch == ':' and !chk.colon_ok)) {
                diag.bad = chk.which;
                return error.BadComponent;
            }
        }
    }
    if (c.user) |v| user = v;
    if (c.role) |v| role = v;
    if (c.type) |v| typ = v;
    if (c.range) |v| range = v;

    // As libselinux does, a range that was given (even an empty one) leaves its
    // colon: "u:r:t:s0" with the range set to "" becomes "u:r:t:".
    if (had_range or c.range != null) return std.fmt.allocPrint(gpa, "{s}:{s}:{s}:{s}", .{ user, role, typ, range });
    return std.fmt.allocPrint(gpa, "{s}:{s}:{s}", .{ user, role, typ });
}

// ---------------------------------------------------------------------------
// File contexts.

pub const XattrError = error{
    NoContext, // ENODATA: the file has no context
    NotSupported,
    FileNotFound,
    NotDir,
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    NameTooLong,
    ReadOnlyFileSystem,
    NoSpaceLeft,
    InvalidArgument,
    SystemResources,
    Unsupported,
    Unexpected,
};

fn xerr(e: linux.E) XattrError {
    return switch (e) {
        .NODATA => error.NoContext,
        .OPNOTSUPP => error.NotSupported,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .ROFS => error.ReadOnlyFileSystem,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .INVAL => error.InvalidArgument,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Text for an `XattrError` as strerror() would give it.
pub fn describe(e: XattrError) []const u8 {
    return switch (e) {
        error.NoContext => "No data available",
        error.NotSupported => "Operation not supported",
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Operation not permitted",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.NoSpaceLeft => "No space left on device",
        error.InvalidArgument => "Invalid argument",
        error.SystemResources => "Cannot allocate memory",
        error.Unsupported => "Operation not supported",
        error.Unexpected => "Unknown error",
    };
}

fn cstr(buf: []u8, text: []const u8) XattrError![:0]const u8 {
    if (text.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

/// The context of `path`, without its terminating NUL, in memory owned by the
/// caller. With `follow` false the file is the symbolic link itself.
pub fn getFileContext(gpa: Allocator, path: []const u8, follow: bool) (XattrError || Allocator.Error)![]u8 {
    if (comptime !is_linux) return error.Unsupported;
    var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    const p = try cstr(&pbuf, path);
    var buf: [4096]u8 = undefined;
    const rc = if (follow)
        linux.getxattr(p, xattr_name, &buf, buf.len)
    else
        linux.lgetxattr(p, xattr_name, &buf, buf.len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return xerr(e);
    return gpa.dupe(u8, std.mem.sliceTo(buf[0..rc], 0));
}

/// Set the context of `path`, storing the text with a terminating NUL as
/// libselinux does.
pub fn setFileContext(path: []const u8, context: []const u8, follow: bool) XattrError!void {
    if (comptime !is_linux) return error.Unsupported;
    var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    const p = try cstr(&pbuf, path);
    var vbuf: [4097]u8 = undefined;
    if (context.len >= vbuf.len) return error.NameTooLong;
    @memcpy(vbuf[0..context.len], context);
    vbuf[context.len] = 0;
    const len = context.len + 1;
    const rc = if (follow)
        linux.setxattr(p, xattr_name, &vbuf, len, 0)
    else
        linux.lsetxattr(p, xattr_name, &vbuf, len, 0);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return xerr(e);
}

// ---------------------------------------------------------------------------
// The process context.

/// True when the running kernel has SELinux with a policy loaded: selinuxfs is
/// mounted and the process context is not the pre-policy "kernel" one.
pub fn enabled(io: Io, gpa: Allocator) bool {
    if (comptime !is_linux) return false;
    const mounts = readSmall(io, gpa, "/proc/mounts") orelse return false;
    defer gpa.free(mounts);
    var mounted = false;
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        _ = f.next();
        if (f.next()) |fstype| {
            if (std.mem.eql(u8, fstype, "selinuxfs")) mounted = true;
        }
    }
    if (!mounted) return false;
    const cur = currentContext(io, gpa) orelse return false;
    defer gpa.free(cur);
    return !std.mem.eql(u8, cur, "kernel");
}

/// The context of this process (/proc/self/attr/current), owned by the caller.
pub fn currentContext(io: Io, gpa: Allocator) ?[]u8 {
    const text = readSmall(io, gpa, "/proc/self/attr/current") orelse return null;
    defer gpa.free(text);
    return gpa.dupe(u8, std.mem.trimEnd(u8, std.mem.sliceTo(text, 0), "\n")) catch null;
}

fn readSmall(io: Io, gpa: Allocator, path: []const u8) ?[]u8 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch null;
}

pub const ExecContextError = error{ InvalidArgument, AccessDenied, Unsupported, Unexpected };

/// Make the next execve() run in `context` (writes /proc/self/attr/exec). The
/// setting applies to this thread only.
pub fn setExecContext(io: Io, context: []const u8) ExecContextError!void {
    if (comptime !is_linux) return error.Unsupported;
    const f = Io.Dir.cwd().openFile(io, "/proc/self/attr/exec", .{ .mode = .write_only }) catch |e| return switch (e) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.Unexpected,
    };
    defer f.close(io);
    var buf: [4097]u8 = undefined;
    if (context.len >= buf.len) return error.InvalidArgument;
    @memcpy(buf[0..context.len], context);
    buf[context.len] = 0;
    // The error number matters here (EINVAL: the kernel rejected the context),
    // so write(2) is called directly rather than through std.Io.
    const rc = linux.write(f.handle, &buf, context.len + 1);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INVAL => error.InvalidArgument,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}

test "editing a context replaces only the given components" {
    const t = std.testing;
    var d: Edit = .{};
    const a = try edit(t.allocator, "u:r:t:s0:c1.c3", .{ .type = "newt" }, &d);
    defer t.allocator.free(a);
    try t.expectEqualStrings("u:r:newt:s0:c1.c3", a);
    const b = try edit(t.allocator, "u:r:t", .{ .range = "s0:c1" }, &d);
    defer t.allocator.free(b);
    try t.expectEqualStrings("u:r:t:s0:c1", b);
    const c = try edit(t.allocator, "u:r:t:s0", .{ .user = "x", .role = "y", .range = "" }, &d);
    defer t.allocator.free(c);
    try t.expectEqualStrings("x:y:t:", c);
    try t.expectError(error.BadContext, edit(t.allocator, "ctx", .{ .type = "x" }, &d));
    try t.expectError(error.BadContext, edit(t.allocator, "u:r", .{ .type = "x" }, &d));
    try t.expectError(error.BadComponent, edit(t.allocator, "u:r:t", .{ .type = "a:b" }, &d));
    try t.expectEqual(@as(?Which, .type), d.bad);
}

test "a file context round trips through the attribute" {
    if (!is_linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(std.testing.io, "f", .{});
    f.close(std.testing.io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, "f", &buf);
    const path = buf[0..n];
    // Whether the file system lets an ordinary user set security.* varies
    // (tmpfs and ext4 do; overlay and some network file systems do not).
    setFileContext(path, "u:r:t:s0", true) catch |e| switch (e) {
        error.NotSupported, error.PermissionDenied, error.AccessDenied => return error.SkipZigTest,
        else => return e,
    };
    const got = try getFileContext(std.testing.allocator, path, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("u:r:t:s0", got);
}
