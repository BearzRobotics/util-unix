// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: passwd(5) and group(5) text (lib/userdb.zig). Pattern: see
//! src/fuzz/seed.zig and the util-core decision on fuzzing. Invariants: no crash, no
//! leak, lookups agree with the parsed entries, no field of a parsed line holds the
//! field separator.

const std = @import("std");
const uu = @import("util_unix");
const userdb = uu.userdb;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

const sample_passwd = "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" ++
    "alice:x:1000:1000:Alice Smith,,,:/home/alice:/bin/sh\n# comment\n\nbad:line\n:x:5:5::/:/bin/sh\n" ++
    "big:x:4294967295:4294967296:x:/:\n";
const sample_group = "root:x:0:\nadm:x:4:syslog,alice\nalice:x:1000:\nusers:x:100:alice,bob\n+:::\nx:y:z\n";

fn userdbText(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var pbuf: [768]u8 = undefined;
    var gbuf: [768]u8 = undefined;
    var kbuf: [48]u8 = undefined;
    const pw_text = pbuf[0..smith.slice(&pbuf)];
    const gr_text = gbuf[0..smith.slice(&gbuf)];
    const key = kbuf[0..smith.slice(&kbuf)];
    const uid = smith.value(u32);

    var db = try userdb.Db.fromText(gpa, pw_text, gr_text);
    defer db.deinit();

    var users: usize = 0;
    var it = db.passwdIterator();
    while (it.next()) |e| {
        users += 1;
        try std.testing.expect(e.name.len > 0);
        for ([_][]const u8{ e.name, e.passwd, e.gecos, e.dir, e.shell }) |f|
            try std.testing.expect(std.mem.indexOfScalar(u8, f, ':') == null);
        // A name finds the first entry of that name, an id the first of that id.
        const by_name = db.userByName(e.name).?;
        try std.testing.expectEqualStrings(e.name, by_name.name);
        try std.testing.expectEqual(e.uid, db.userById(e.uid).?.uid);
    }
    var groups: usize = 0;
    var git = db.groupIterator();
    while (git.next()) |g| {
        groups += 1;
        try std.testing.expect(g.name.len > 0);
        for ([_][]const u8{ g.name, g.passwd }) |f| try std.testing.expect(std.mem.indexOfScalar(u8, f, ':') == null);
        try std.testing.expectEqualStrings(g.name, db.groupByName(g.name).?.name);
        try std.testing.expectEqual(g.gid, db.groupById(g.gid).?.gid);
        const list = try db.groupsOf(g.name, g.gid);
        defer gpa.free(list);
        // The primary group is in the list exactly once.
        var n: usize = 0;
        for (list) |x| {
            if (x == g.gid) n += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    if (db.userByName(key)) |e| try std.testing.expectEqualStrings(key, e.name);
    if (db.groupByName(key)) |g| try std.testing.expectEqualStrings(key, g.name);
    if (db.userById(uid)) |e| try std.testing.expectEqual(uid, e.uid);
    if (db.groupById(uid)) |g| try std.testing.expectEqual(uid, g.gid);
    _ = userdb.parsePasswd(key);
    _ = userdb.parseGroup(key);

    const list = try db.groupsOf(key, uid);
    gpa.free(list);
    if (users == 0) try std.testing.expect(db.userByName(key) == null);
    if (groups == 0) try std.testing.expect(db.groupByName(key) == null);
}

test "fuzz: passwd and group text and lookups" {
    try engine.fuzz({}, seed_mod.capped(void, userdbText), .{ .name = "userdb-userdbText", .corpus = &.{
        seed(.{ sample_passwd, sample_group, "alice" }),
        seed(.{ "root:x:0:0:::\n", "g:x:0:root,root,root\n", "root" }),
        seed(.{ "", "", "" }),
        seed(.{ "\n\n::::::\n:::\n", "::\n:\n", "\x00" }),
    } });
}
