// SPDX-License-Identifier: GPL-2.0-or-later
//! id and groups: print user and group identities.
//!
//! References: POSIX.1-2024 id
//! (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/id.html);
//! GNU coreutils 9.7 manual, "id invocation" and "groups invocation" (-n, -r,
//! -z, the default format, the order of the group list).
//!
//! Names come from the files-only user database (`userdb.zig`, decision
//! 0004). The security context (`id -Z`) is not supported.
//!
//! This module formats; it does not find the process's own credentials
//! (`proc.zig`) or decide how to warn. An id with no name is printed as a
//! number and reported through `Options.unnamed`, so the caller can print the
//! warning in the right place relative to the output.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const userdb = @import("userdb.zig");

pub const Which = enum {
    /// uid=1000(alice) gid=1000(alice) groups=1000(alice),...
    default,
    /// -u
    user,
    /// -g
    group,
    /// -G
    groups,
};

pub const Kind = enum { user, group };

/// Called when `-n` wants a name for `id` and the database has none.
pub const Unnamed = struct {
    context: ?*anyopaque = null,
    on_unnamed: *const fn (context: ?*anyopaque, kind: Kind, id: u32) void,
};

pub const Options = struct {
    which: Which = .default,
    /// -n: names instead of numbers (with `.user`, `.group`, `.groups`).
    names: bool = false,
    /// -r: real instead of effective ids (with `.user`, `.group`, `.groups`).
    real: bool = false,
    /// -z: NUL instead of whitespace delimiters (not for `.default`).
    zero: bool = false,
    unnamed: ?Unnamed = null,
};

/// The ids to describe. `groups` are supplementary groups in any order; the
/// primary group is placed first and not repeated.
pub const Ids = struct {
    uid: u32,
    euid: u32,
    gid: u32,
    egid: u32,
    groups: []const u32,
};

/// Look a user up by name, falling back to a decimal uid when no user has
/// that name (so `id 0` works unless a user is called "0"), as GNU does.
pub fn findUser(db: *const userdb.Db, text: []const u8) ?userdb.Passwd {
    if (db.userByName(text)) |u| return u;
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    return db.userById(n);
}

/// Ids of a database user: its groups come from `Db.groupsOf`. The caller
/// frees `groups` with the allocator the database was loaded with.
pub fn idsOfUser(db: *const userdb.Db, pw: userdb.Passwd) Allocator.Error!Ids {
    return .{
        .uid = pw.uid,
        .euid = pw.uid,
        .gid = pw.gid,
        .egid = pw.gid,
        .groups = try db.groupsOf(pw.name, pw.gid),
    };
}

/// Write one description. Returns false when some name was missing (the id
/// is printed as a number instead).
pub fn write(w: *Io.Writer, db: *const userdb.Db, opts: Options, ids: Ids) Io.Writer.Error!bool {
    const term: u8 = if (opts.zero) 0 else '\n';
    switch (opts.which) {
        .user => {
            const id = if (opts.real) ids.uid else ids.euid;
            const ok = try writeOne(w, db, opts, .user, id);
            try w.writeByte(term);
            return ok;
        },
        .group => {
            const id = if (opts.real) ids.gid else ids.egid;
            const ok = try writeOne(w, db, opts, .group, id);
            try w.writeByte(term);
            return ok;
        },
        .groups => {
            // The primary group first, then the others without repeating it.
            const primary = if (opts.real) ids.gid else ids.egid;
            const sep: u8 = if (opts.zero) 0 else ' ';
            var ok = try writeOne(w, db, opts, .group, primary);
            for (ids.groups) |g| {
                if (g == primary) continue;
                try w.writeByte(sep);
                ok = (try writeOne(w, db, opts, .group, g)) and ok;
            }
            try w.writeByte(term);
            return ok;
        },
        .default => {
            try w.print("uid={d}", .{ids.uid});
            try writeLabel(w, userName(db, ids.uid));
            try w.print(" gid={d}", .{ids.gid});
            try writeLabel(w, groupName(db, ids.gid));
            if (ids.euid != ids.uid) {
                try w.print(" euid={d}", .{ids.euid});
                try writeLabel(w, userName(db, ids.euid));
            }
            if (ids.egid != ids.gid) {
                try w.print(" egid={d}", .{ids.egid});
                try writeLabel(w, groupName(db, ids.egid));
            }
            try w.writeAll(" groups=");
            try w.print("{d}", .{ids.egid});
            try writeLabel(w, groupName(db, ids.egid));
            for (ids.groups) |g| {
                if (g == ids.egid) continue;
                try w.print(",{d}", .{g});
                try writeLabel(w, groupName(db, g));
            }
            try w.writeByte('\n');
            return true;
        },
    }
}

fn userName(db: *const userdb.Db, uid: u32) ?[]const u8 {
    return if (db.userById(uid)) |u| u.name else null;
}

fn groupName(db: *const userdb.Db, gid: u32) ?[]const u8 {
    return if (db.groupById(gid)) |g| g.name else null;
}

fn writeLabel(w: *Io.Writer, name: ?[]const u8) Io.Writer.Error!void {
    if (name) |n| try w.print("({s})", .{n});
}

fn writeOne(w: *Io.Writer, db: *const userdb.Db, opts: Options, kind: Kind, id: u32) Io.Writer.Error!bool {
    if (opts.names) {
        const name = switch (kind) {
            .user => userName(db, id),
            .group => groupName(db, id),
        };
        if (name) |n| {
            try w.writeAll(n);
            return true;
        }
        // The warning must appear before the number it accompanies.
        if (opts.unnamed) |u| {
            try w.flush();
            u.on_unnamed(u.context, kind, id);
        }
        try w.print("{d}", .{id});
        return false;
    }
    try w.print("{d}", .{id});
    return true;
}

const test_passwd = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n";
const test_group = "root:x:0:\nalice:x:1000:\nstaff:x:50:alice\n";

fn expectWrite(opts: Options, ids: Ids, want: []const u8, want_ok: bool) !void {
    var db = try userdb.Db.fromText(std.testing.allocator, test_passwd, test_group);
    defer db.deinit();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const ok = try write(&w, &db, opts, ids);
    try std.testing.expectEqualStrings(want, w.buffered());
    try std.testing.expectEqual(want_ok, ok);
}

test "default format names what it can and lists the effective group first" {
    const ids: Ids = .{ .uid = 1000, .euid = 1000, .gid = 1000, .egid = 1000, .groups = &.{ 50, 1000, 77 } };
    try expectWrite(.{}, ids, "uid=1000(alice) gid=1000(alice) groups=1000(alice),50(staff),77\n", true);
}

test "default format shows euid and egid only when they differ" {
    const ids: Ids = .{ .uid = 1000, .euid = 0, .gid = 1000, .egid = 0, .groups = &.{} };
    try expectWrite(.{}, ids, "uid=1000(alice) gid=1000(alice) euid=0(root) egid=0(root) groups=0(root)\n", true);
}

test "-u -g -G with -n -r -z" {
    const ids: Ids = .{ .uid = 1000, .euid = 0, .gid = 1000, .egid = 0, .groups = &.{ 50, 0 } };
    try expectWrite(.{ .which = .user }, ids, "0\n", true);
    try expectWrite(.{ .which = .user, .real = true, .names = true }, ids, "alice\n", true);
    try expectWrite(.{ .which = .group, .names = true }, ids, "root\n", true);
    try expectWrite(.{ .which = .groups, .names = true }, ids, "root staff\n", true);
    try expectWrite(.{ .which = .groups, .zero = true }, ids, "0\x0050\x00", true);
}

test "an unnamed id is printed as a number, reported, and makes the result false" {
    const Seen = struct {
        var count: u32 = 0;
        var last: u32 = 0;
        fn cb(_: ?*anyopaque, _: Kind, id: u32) void {
            count += 1;
            last = id;
        }
    };
    const ids: Ids = .{ .uid = 1, .euid = 1, .gid = 99, .egid = 99, .groups = &.{} };
    try expectWrite(.{ .which = .group, .names = true, .unnamed = .{ .on_unnamed = Seen.cb } }, ids, "99\n", false);
    try std.testing.expectEqual(@as(u32, 1), Seen.count);
    try std.testing.expectEqual(@as(u32, 99), Seen.last);
}

test "findUser prefers a name over a number and falls back to a uid" {
    var db = try userdb.Db.fromText(std.testing.allocator, "1000:x:5:5::/:/bin/sh\nalice:x:1000:1000::/:/bin/sh\n", "");
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 5), findUser(&db, "1000").?.uid); // the user named "1000"
    try std.testing.expectEqualStrings("alice", findUser(&db, "alice").?.name);
    try std.testing.expectEqualStrings("1000", findUser(&db, "5").?.name); // no name "5": uid 5
    try std.testing.expect(findUser(&db, "77") == null);
}
