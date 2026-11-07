// SPDX-License-Identifier: GPL-2.0-or-later
//! Parsing of `[OWNER][:[GROUP]]` specifications, as used by chown, chgrp and
//! `chown --from`.
//!
//! Reference: GNU coreutils 9.7 manual, "chown invocation" and
//! "Disambiguating names and IDs"; POSIX.1-2024 `chown` (owner[:group] with
//! numeric ids and names); gnulib `lib/userspec.c` (read as the behavioural
//! reference for the corner cases below, not copied).
//!
//! Rules, in order:
//!  - The separator is the first ':'. If there is no ':' and the whole spec is
//!    not a user name, a '.' is tried as an old-style separator and succeeds
//!    with `warn_dot` set ("'.' should be ':'").
//!  - A part that names an existing user (group) is that user (group), even if
//!    it looks like a number. Otherwise a decimal number is taken as an id. A
//!    leading '+' skips the name lookup and forces the numeric reading.
//!  - "OWNER:" (separator, empty group) means OWNER's login group; it needs
//!    OWNER to exist as a name.
//!  - Missing parts mean "unchanged" (null).

const std = @import("std");
const userdb = @import("userdb.zig");

pub const Mode = enum {
    /// `[OWNER][:GROUP]` (chown, chown --from).
    user_and_group,
    /// The whole text is a user (no group part).
    user_only,
};

pub const ParseError = error{ InvalidSpec, InvalidUser, InvalidGroup };

pub const Parsed = struct {
    uid: ?u32 = null,
    gid: ?u32 = null,
    /// The owner as typed, when it was resolved by name (null for a numeric id
    /// or when no owner was given). Borrows from the spec or the database.
    user_name: ?[]const u8 = null,
    /// The group as typed or, for "OWNER:", the login group's name.
    group_name: ?[]const u8 = null,
    /// A '.' was used as the separator; callers should warn.
    warn_dot: bool = false,
};

/// Text GNU uses for each error ("invalid user" ...).
pub fn errorText(e: ParseError) []const u8 {
    return switch (e) {
        error.InvalidSpec => "invalid spec",
        error.InvalidUser => "invalid user",
        error.InvalidGroup => "invalid group",
    };
}

/// Parse `spec`. `db` supplies the user and group names.
pub fn parse(db: *const userdb.Db, spec: []const u8, mode: Mode) ParseError!Parsed {
    const colon: ?usize = if (mode == .user_and_group) std.mem.indexOfScalar(u8, spec, ':') else null;
    if (withSeparator(db, spec, colon)) |parsed| return parsed else |first| {
        if (mode == .user_and_group and colon == null) {
            if (std.mem.indexOfScalar(u8, spec, '.')) |dot| {
                if (withSeparator(db, spec, dot)) |parsed| {
                    var p = parsed;
                    p.warn_dot = true;
                    return p;
                } else |_| {}
            }
        }
        return first;
    }
}

fn withSeparator(db: *const userdb.Db, spec: []const u8, sep: ?usize) ParseError!Parsed {
    const u: ?[]const u8 = if (sep) |s| (if (s != 0) spec[0..s] else null) else (if (spec.len != 0) spec else null);
    const g: ?[]const u8 = if (sep) |s| (if (s + 1 < spec.len) spec[s + 1 ..] else null) else null;

    var out: Parsed = .{};
    if (u) |user| {
        const entry = if (user[0] == '+') null else db.userByName(user);
        if (entry) |pw| {
            out.uid = pw.uid;
            out.user_name = user;
            if (g == null and sep != null) {
                // "OWNER:" - use the owner's login group.
                out.gid = pw.gid;
                out.group_name = if (db.groupById(pw.gid)) |gr| gr.name else null;
            }
        } else {
            // A trailing separator with no group needs a real user.
            if (sep != null and g == null) return error.InvalidSpec;
            out.uid = parseNumericId(user) orelse return error.InvalidUser;
        }
    }
    if (g) |group| {
        const entry = if (group[0] == '+') null else db.groupByName(group);
        if (entry) |gr| {
            out.gid = gr.gid;
            out.group_name = group;
        } else {
            out.gid = parseNumericId(group) orelse return error.InvalidGroup;
            out.group_name = null;
        }
    }
    return out;
}

/// strtoul-style decimal id: optional blanks and '+', digits, nothing else;
/// the value must fit and must not be the "unchanged" sentinel 2^32-1.
fn parseNumericId(text: []const u8) ?u32 {
    var s = text;
    while (s.len > 0 and std.ascii.isWhitespace(s[0])) s = s[1..];
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(u32)) return null;
    }
    if (v == std.math.maxInt(u32)) return null;
    return @intCast(v);
}

const test_passwd =
    \\root:x:0:0:root:/root:/bin/bash
    \\alice:x:1000:100:Alice:/home/alice:/bin/sh
    \\1234:x:77:77::/:/bin/false
    \\dot.user:x:2000:2000::/:/bin/sh
    \\
;
const test_group =
    \\root:x:0:
    \\users:x:100:
    \\staff:x:50:
    \\4321:x:88:
    \\
;

fn tdb() !userdb.Db {
    return userdb.Db.fromText(std.testing.allocator, test_passwd, test_group);
}

test "owner only, group only, both" {
    var db = try tdb();
    defer db.deinit();
    const a = try parse(&db, "alice", .user_and_group);
    try std.testing.expectEqual(@as(?u32, 1000), a.uid);
    try std.testing.expectEqual(@as(?u32, null), a.gid);
    try std.testing.expectEqualStrings("alice", a.user_name.?);
    const b = try parse(&db, ":staff", .user_and_group);
    try std.testing.expectEqual(@as(?u32, null), b.uid);
    try std.testing.expectEqual(@as(?u32, 50), b.gid);
    try std.testing.expectEqualStrings("staff", b.group_name.?);
    const c = try parse(&db, "alice:staff", .user_and_group);
    try std.testing.expectEqual(@as(?u32, 1000), c.uid);
    try std.testing.expectEqual(@as(?u32, 50), c.gid);
}

test "OWNER: means the login group; ':' alone changes nothing" {
    var db = try tdb();
    defer db.deinit();
    const a = try parse(&db, "alice:", .user_and_group);
    try std.testing.expectEqual(@as(?u32, 100), a.gid);
    try std.testing.expectEqualStrings("users", a.group_name.?);
    const none = try parse(&db, ":", .user_and_group);
    try std.testing.expectEqual(@as(?u32, null), none.uid);
    try std.testing.expectEqual(@as(?u32, null), none.gid);
    try std.testing.expectError(error.InvalidSpec, parse(&db, "42:", .user_and_group));
}

test "numbers: names win, '+' forces numeric, unknown numbers are ids" {
    var db = try tdb();
    defer db.deinit();
    try std.testing.expectEqual(@as(?u32, 77), (try parse(&db, "1234", .user_and_group)).uid); // user named 1234
    try std.testing.expectEqual(@as(?u32, 1234), (try parse(&db, "+1234", .user_and_group)).uid);
    try std.testing.expectEqual(@as(?u32, 88), (try parse(&db, ":4321", .user_and_group)).gid); // group named 4321
    try std.testing.expectEqual(@as(?u32, 999), (try parse(&db, "999:999", .user_and_group)).uid);
    try std.testing.expectError(error.InvalidUser, parse(&db, "nosuch", .user_and_group));
    try std.testing.expectError(error.InvalidGroup, parse(&db, ":nosuch", .user_and_group));
    try std.testing.expectError(error.InvalidUser, parse(&db, "4294967295", .user_and_group)); // (uid_t)-1
    try std.testing.expectError(error.InvalidUser, parse(&db, "-1", .user_and_group));
    try std.testing.expectEqual(@as(?u32, 4294967294), (try parse(&db, "4294967294", .user_and_group)).uid);
}

test "dot separator: tried only after the whole spec fails as a name" {
    var db = try tdb();
    defer db.deinit();
    const a = try parse(&db, "alice.staff", .user_and_group);
    try std.testing.expect(a.warn_dot);
    try std.testing.expectEqual(@as(?u32, 1000), a.uid);
    try std.testing.expectEqual(@as(?u32, 50), a.gid);
    const d = try parse(&db, "dot.user", .user_and_group); // a user whose name has a dot
    try std.testing.expect(!d.warn_dot);
    try std.testing.expectEqual(@as(?u32, 2000), d.uid);
    try std.testing.expectError(error.InvalidUser, parse(&db, "bob.staff", .user_and_group));
}

test "user_only treats ':' as part of the name" {
    var db = try tdb();
    defer db.deinit();
    try std.testing.expectError(error.InvalidUser, parse(&db, "alice:staff", .user_only));
    try std.testing.expectEqual(@as(?u32, 1000), (try parse(&db, "alice", .user_only)).uid);
}
