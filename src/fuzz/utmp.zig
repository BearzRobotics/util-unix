// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: utmp files (lib/utmp.zig) and `who` selection and formatting
//! (lib/who.zig) on arbitrary bytes taken as a utmp file. Invariants: the record
//! decoder never crashes, text output is whole lines, JSON output always parses
//! (decision 0007), and time/idle formatting takes any instant.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const utmp = uu.utmp;
const who = uu.who;
const localtime = uu.localtime;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn decode(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    var buf: [utmp.record_size * 3 + 17]u8 = undefined;
    const data = buf[0..smith.slice(&buf)];
    const n = utmp.count(data);
    try std.testing.expectEqual(data.len / utmp.record_size, n);
    var i: usize = 0;
    while (i < n + 2) : (i += 1) {
        const r = utmp.record(data, i);
        if ((i < n) != (r != null)) return error.TestUnexpectedResult;
        const r2 = r orelse continue;
        for ([_][]const u8{ r2.line, r2.user, r2.host }) |f|
            try std.testing.expect(std.mem.indexOfScalar(u8, f, 0) == null);
        try std.testing.expect(utmp.idText(r2).len <= 4);
        _ = utmp.isUserProcess(r2);
    }
    try std.testing.expect(utmp.record(data, std.math.maxInt(usize)) == null);
}

fn flagBits(bits: u16, now: i64, my_line: []const u8) who.Options {
    var o: who.Options = .{ .now = now };
    o.users = bits & 1 != 0;
    o.boot = bits & 2 != 0;
    o.dead = bits & 4 != 0;
    o.login = bits & 8 != 0;
    o.init_spawn = bits & 16 != 0;
    o.runlevel = bits & 32 != 0;
    o.clock_change = bits & 64 != 0;
    o.include_idle = bits & 128 != 0;
    o.include_mesg = bits & 256 != 0;
    o.include_exit = bits & 512 != 0;
    o.short = bits & 1024 != 0;
    o.heading = bits & 2048 != 0;
    o.count = bits & 4096 != 0;
    o.my_line_only = bits & 8192 != 0;
    o.my_line = if (bits & 16384 != 0) my_line else null;
    o.style = if (bits & 32768 != 0) .iso else .classic;
    o.finish();
    return o;
}

fn whoRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var buf: [utmp.record_size * 3]u8 = undefined;
    var lbuf: [16]u8 = undefined;
    const data = buf[0..smith.slice(&buf)];
    const my_line = lbuf[0..smith.slice(&lbuf)];
    const fuzzed_bits = smith.value(u16);
    const now = smith.value(i64);
    // The fuzzed selection plus fixed ones, so every corpus entry exercises every
    // record kind and column.
    for ([_]u16{ fuzzed_bits, 0x007f, 0xffff, 0x2d81, 0x4001 }) |bits| {
        const o = flagBits(bits, now, my_line);

        var zone: localtime.Zone = .{};
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try who.write(std.testing.io, &out.writer, data, &zone, o);
        const text = out.written();
        if (text.len > 0) try std.testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);

        var j: Io.Writer.Allocating = .init(gpa);
        defer j.deinit();
        try who.writeJson(std.testing.io, &j.writer, data, o);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, j.written(), .{});
        parsed.deinit();
    }
}

fn timeFormat(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    const ts = smith.value(i64);
    const last = smith.value(i64);
    const now = smith.value(i64);
    const boot = smith.value(i64);
    var zone: localtime.Zone = .{};
    var b1: [64]u8 = undefined;
    var b2: [32]u8 = undefined;
    inline for (.{ who.TimeStyle.iso, who.TimeStyle.classic }) |style| {
        const t = who.formatTime(&b1, style, &zone, ts);
        // A year can have more than four digits, but not more than the style's width + 12.
        try std.testing.expect(t.len > 0 and t.len < 32);
    }
    _ = who.idleText(&b2, last, now, boot);
    _ = who.idleText(&b2, null, now, boot);
    _ = uu.pinky.idleText(&b2, last, now);
}

/// One 384-byte record with the given type, user, line and host.
fn rec(comptime kind: i16, comptime user: []const u8, comptime line: []const u8, comptime host: []const u8, comptime time: i32) [utmp.record_size]u8 {
    @setEvalBranchQuota(10000);
    var r: [utmp.record_size]u8 = @splat(0);
    const e = @import("builtin").cpu.arch.endian();
    std.mem.writeInt(i16, r[0..2], kind, e);
    std.mem.writeInt(i32, r[4..8], 4242, e);
    @memcpy(r[8..][0..line.len], line);
    @memcpy(r[40..44], "ts/1");
    @memcpy(r[44..][0..user.len], user);
    @memcpy(r[76..][0..host.len], host);
    std.mem.writeInt(i32, r[340..344], time, e);
    return r;
}

const sample = rec(2, "reboot", "~", "6.1.0", 1762500000) ++
    rec(7, "alice", "pts/3", "example.org", 1762518896) ++
    rec(7, "bob", "null", "", 1762518000) ++
    rec(1, "runlevel", "~", "", 1762400000);

test "fuzz: utmp record decoding" {
    try engine.fuzz({}, seed_mod.capped(void, decode), .{ .name = "utmp-decode", .corpus = &.{
        seed(.{""}),
        seed(.{&sample}),
        seed(.{sample[0..383]}),
        seed(.{&(@as([utmp.record_size]u8, @splat(0xff)))}),
    } });
}

test "fuzz: who on arbitrary utmp data" {
    try engine.fuzz({}, seed_mod.capped(void, whoRun), .{ .name = "utmp-whoRun", .corpus = &.{
        seed(.{ &sample, "pts/3" }),
        seed(.{ sample[0..384], "" }),
        seed(.{ sample[384..768], "null" }),
        seed(.{ "", "" }),
        seed(.{ &(@as([utmp.record_size]u8, @splat(0xff))), "\xff" }),
    } });
}

test "fuzz: who time formatting and idle text on any instant" {
    try engine.fuzz({}, seed_mod.capped(void, timeFormat), .{ .name = "utmp-timeFormat", .corpus = &.{
        "",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        "\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x80\xff\xff\xff\xff\xff\xff\xff\x7f",
    } });
}
