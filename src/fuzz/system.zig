// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: uname formatting (lib/uname.zig) on arbitrary utsname contents, host-name
//! helpers and hosts-file name completion (lib/hostname.zig; the host name is never
//! set), and local time conversion (lib/localtime.zig) for any instant and any TZif
//! file. Invariants: no crash, no leak, JSON output always parses.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const uu = @import("util_unix");
const uname = uu.uname;
const hostname = uu.hostname;
const localtime = uu.localtime;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn unameRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    if (comptime builtin.os.tag != .linux) return;
    var raw = std.mem.zeroes(std.os.linux.utsname);
    var buf: [6 * 64]u8 = undefined;
    @memset(&buf, 0);
    _ = smith.slice(&buf);
    inline for (@typeInfo(std.os.linux.utsname).@"struct".field_names, 0..) |name, i| {
        if (i < 6) @memcpy(&@field(raw, name), buf[i * 64 ..][0..64]);
    }
    const info: uu.proc.Uname = .{ .raw = raw };
    for (0..256) |bits| {
        const f: uname.Fields = .{
            .kernel_name = bits & 1 != 0,
            .nodename = bits & 2 != 0,
            .kernel_release = bits & 4 != 0,
            .kernel_version = bits & 8 != 0,
            .machine = bits & 16 != 0,
            .processor = bits & 32 != 0,
            .hardware_platform = bits & 64 != 0,
            .operating_system = bits & 128 != 0,
        };
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try uname.write(&info, f, &out.writer);
        try std.testing.expectEqual(@as(u8, '\n'), out.written()[out.written().len - 1]);
        var j: Io.Writer.Allocating = .init(gpa);
        defer j.deinit();
        try uname.writeJson(&info, f, &j.writer);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, j.written(), .{});
        parsed.deinit();
    }
}

fn hostnameRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var tbuf: [768]u8 = undefined;
    var nbuf: [48]u8 = undefined;
    const text = tbuf[0..smith.slice(&tbuf)];
    const name = nbuf[0..smith.slice(&nbuf)];

    const s = hostname.short(name);
    try std.testing.expect(std.mem.indexOfScalar(u8, s, '.') == null);
    if (hostname.domain(name)) |d| try std.testing.expectEqual(name.len, s.len + 1 + d.len);
    if (hostname.fromFileText(text)) |l| {
        try std.testing.expect(l.len > 0 and l[0] != '#');
        try std.testing.expect(std.mem.indexOfScalar(u8, l, '\n') == null);
    }
    if (try hostname.lookup(gpa, text, name)) |m| {
        defer m.deinit(gpa);
        try std.testing.expect(m.canonical.len > 0);
        for (m.addresses) |a| try std.testing.expect(a.len > 0);
    }
    // The first name of a hosts line always finds the line.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| : (n += 1) {
        if (n == 8) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        var f = std.mem.tokenizeAny(u8, line, " \t");
        if (line.len > 0 and std.mem.indexOfScalar(u8, line, '#') == null) {
            _ = f.next() orelse continue;
            const first = f.next() orelse continue;
            if (try hostname.lookup(gpa, text, first)) |m| m.deinit(gpa) else return error.TestUnexpectedResult;
        }
    }
}

fn civilRun(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    const ts = smith.value(i64);
    const l = localtime.civil(ts);
    try std.testing.expect(l.month >= 1 and l.month <= 12);
    try std.testing.expect(l.day >= 1 and l.day <= 31);
    try std.testing.expect(l.hour < 24 and l.minute < 60 and l.second < 60 and l.weekday < 7);
    var zone: localtime.Zone = .{};
    _ = zone.local(ts);
}

/// A minimal valid TZif (version 1) file: two types, two transitions.
fn tzif() [44 + 2 * 4 + 2 + 2 * 6 + 9]u8 {
    var b: [44 + 2 * 4 + 2 + 2 * 6 + 9]u8 = @splat(0);
    @memcpy(b[0..4], "TZif");
    // ttisutcnt, ttisstdcnt, leapcnt, timecnt, typecnt, charcnt
    const counts = [_]u32{ 0, 0, 0, 2, 2, 9 };
    for (counts, 0..) |c, i| std.mem.writeInt(u32, b[20 + 4 * i ..][0..4], c, .big);
    var p: usize = 44;
    std.mem.writeInt(i32, b[p..][0..4], 1000, .big);
    std.mem.writeInt(i32, b[p + 4 ..][0..4], 2000, .big);
    p += 8;
    b[p] = 1;
    b[p + 1] = 0;
    p += 2;
    std.mem.writeInt(i32, b[p..][0..4], 3600, .big);
    b[p + 4] = 1;
    b[p + 5] = 0;
    p += 6;
    std.mem.writeInt(i32, b[p..][0..4], -18000, .big);
    b[p + 4] = 0;
    b[p + 5] = 4;
    p += 6;
    @memcpy(b[p..][0..9], "CEST\x00EST\x00");
    return b;
}

fn tzRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var buf: [256]u8 = undefined;
    const data = buf[0..smith.slice(&buf)];
    const ts = smith.value(i64);
    var reader: Io.Reader = .fixed(data);
    const tz = std.tz.Tz.parse(gpa, &reader) catch return;
    var zone: localtime.Zone = .{ .tz = tz };
    defer zone.deinit();
    _ = zone.offsetAt(ts);
    _ = zone.offsetAt(0);
    _ = zone.local(ts);
    _ = zone.local(std.math.minInt(i32));
}

fn zoneNameRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var buf: [48]u8 = undefined;
    const name = buf[0..smith.slice(&buf)];
    // Zone names that are absolute paths would read arbitrary files; the fuzzer stays
    // inside the zoneinfo tree.
    if (name.len > 0 and (name[0] == '/' or (name.len > 1 and name[0] == ':' and name[1] == '/'))) return;
    var zone = try localtime.Zone.load(std.testing.io, gpa, name);
    defer zone.deinit();
    _ = zone.local(1762518896);
}

test "fuzz: uname formatting" {
    try engine.fuzz({}, seed_mod.capped(void, unameRun), .{ .name = "system-unameRun", .corpus = &.{
        seed(.{"Linux\x00\x00\x00"}),
        seed(.{"Linux\x00host\x00\x00\x00\x00\x00\x00\x006.1.0\x00#1 SMP\x00x86_64"}),
        seed(.{"\"\\\n\xff"}),
        seed(.{""}),
    } });
}

test "fuzz: hostname helpers and hosts completion" {
    try engine.fuzz({}, seed_mod.capped(void, hostnameRun), .{ .name = "system-hostnameRun", .corpus = &.{
        seed(.{ "127.0.0.1 localhost\n127.0.1.1 myhost.example.org myhost\n::1 ip6-localhost\n", "MYHOST" }),
        seed(.{ "# c\n\n10.0.0.1 a b c # x\n10.0.0.2 a\n", "a" }),
        seed(.{ "\n\n  \t\n", "x.y.z" }),
        seed(.{ "", "" }),
    } });
}

test "fuzz: local time for any instant and any TZif file" {
    try engine.fuzz({}, seed_mod.capped(void, civilRun), .{ .name = "system-civilRun", .corpus = &.{
        "",
        "\xff\xff\xff\xff\xff\xff\xff\xff",
        "\x00\x00\x00\x00\x00\x00\x00\x80",
        "\xff\xff\xff\xff\xff\xff\xff\x7f",
    } });
    try engine.fuzz({}, seed_mod.capped(void, tzRun), .{ .name = "system-tzRun", .corpus = &.{
        seed(.{&tzif()}),
        seed(.{tzif()[0..30]}),
        seed(.{""}),
    } });
    try engine.fuzz({}, seed_mod.capped(void, zoneNameRun), .{ .name = "system-zoneNameRun", .corpus = &.{
        seed(.{"UTC"}),
        seed(.{"Europe/Paris"}),
        seed(.{":America/New_York"}),
        seed(.{"../../etc/passwd"}),
        seed(.{"EST5EDT,M3.2.0,M11.1.0"}),
        seed(.{""}),
    } });
}
