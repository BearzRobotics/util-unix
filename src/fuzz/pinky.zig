// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: pinky (lib/pinky.zig) long and short formats on an arbitrary passwd text,
//! login names and utmp data. Invariants: no crash, no leak, whole lines, and the real
//! name always fits its buffer.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const pinky = uu.pinky;
const userdb = uu.userdb;
const localtime = uu.localtime;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn realName(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    var gbuf: [300]u8 = undefined;
    var lbuf: [40]u8 = undefined;
    var out: [64]u8 = undefined;
    const gecos = gbuf[0..smith.slice(&gbuf)];
    const login = lbuf[0..smith.slice(&lbuf)];
    const n = pinky.realName(&out, gecos, login);
    try std.testing.expect(n.len <= out.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, n, ',') == null or std.mem.indexOfScalar(u8, login, ',') != null);
}

fn formats(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var pbuf: [512]u8 = undefined;
    var dbuf: [utmp_size * 2]u8 = undefined;
    var ubuf: [32]u8 = undefined;
    const passwd = pbuf[0..smith.slice(&pbuf)];
    const data = dbuf[0..smith.slice(&dbuf)];
    const login = ubuf[0..smith.slice(&ubuf)];
    const bits = smith.value(u8);
    const now = smith.value(i64);

    var db = try userdb.Db.fromText(gpa, passwd, "");
    defer db.deinit();

    var o: pinky.Options = .{ .now = now };
    o.home_and_shell = bits & 1 != 0;
    o.project = bits & 2 != 0;
    o.plan = bits & 4 != 0;
    o.heading = bits & 8 != 0;
    o.fullname = bits & 16 != 0;
    o.where = bits & 32 != 0;
    o.idle = bits & 64 != 0;
    o.style = if (bits & 128 != 0) .iso else .classic;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try pinky.writeLong(std.testing.io, gpa, &out.writer, &db, login, o);
    // Every account the passwd text names, as `pinky -l` would be asked for it.
    var it = db.passwdIterator();
    var seen: usize = 0;
    while (it.next()) |e| : (seen += 1) {
        if (seen == 4) break;
        // Skip homes the fuzzer pointed at something other than a plain directory name.
        try pinky.writeLong(std.testing.io, gpa, &out.writer, &db, e.name, o);
    }
    try std.testing.expect(out.written().len > 0 and out.written()[out.written().len - 1] == '\n');

    var zone: localtime.Zone = .{};
    var short: Io.Writer.Allocating = .init(gpa);
    defer short.deinit();
    try pinky.writeShort(std.testing.io, &short.writer, data, &zone, &db, &.{}, o);
    try pinky.writeShort(std.testing.io, &short.writer, data, &zone, &db, &.{login}, o);
    const text = short.written();
    if (text.len > 0) try std.testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
}

const utmp_size = uu.utmp.record_size;

fn userRecord(comptime user: []const u8, comptime line: []const u8, comptime host: []const u8) [utmp_size]u8 {
    var r: [utmp_size]u8 = @splat(0);
    const e = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(i16, r[0..2], 7, e);
    @memcpy(r[8..][0..line.len], line);
    @memcpy(r[44..][0..user.len], user);
    @memcpy(r[76..][0..host.len], host);
    std.mem.writeInt(i32, r[340..344], 1762518896, e);
    return r;
}

const sample_utmp = userRecord("alice", "pts/3", "h.example") ++ userRecord("bob", "null", "");
const sample_passwd = "alice:x:1000:1000:Alice Smith,Room 5,555:/nonexistent/alice:/bin/bash\n" ++
    "bob:x:1001:1001:&:/nonexistent:/bin/sh\n";

test "fuzz: pinky real names" {
    try engine.fuzz({}, seed_mod.capped(void, realName), .{ .name = "pinky-realName", .corpus = &.{
        seed(.{ "Alice Smith,Room 5", "alice" }),
        seed(.{ "Dr. & Q. Public", "carol" }),
        seed(.{ "&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&", "abcdefghijklmnopqrstuvwxyzabcdefghijklm" }),
        seed(.{ "", "" }),
    } });
}

test "fuzz: pinky long and short formats" {
    try engine.fuzz({}, seed_mod.capped(void, formats), .{ .name = "pinky-formats", .corpus = &.{
        seed(.{ sample_passwd, &sample_utmp, "alice" }),
        seed(.{ sample_passwd, &sample_utmp, "nosuch" }),
        seed(.{ "", "", "" }),
        seed(.{ "x:x:1:1:\xff\xfe:/:/\n", &sample_utmp, "x" }),
    } });
}
