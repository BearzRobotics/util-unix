// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: stty (lib/stty.zig). Settings argument vectors are interpreted with the
//! library's parsing and mode-application functions on an in-memory `Termios`; the
//! formatting functions print arbitrary terminal states. No terminal is ever opened.
//! Invariants: no crash, no leak, whole lines, and `-g` state round-trips.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const st = uu.stty;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

/// What the stty command does with a settings vector, minus the terminal and the
/// diagnostics (the command is a thin wrapper; this is the same sequence of calls).
fn applySettings(t: *st.Termios, items: []const []const u8) void {
    const eql = std.mem.eql;
    var k: usize = 0;
    while (k < items.len) : (k += 1) {
        var arg = items[k];
        var reversed = false;
        if (arg.len > 0 and arg[0] == '-') {
            reversed = true;
            arg = arg[1..];
        }
        if (st.findMode(arg)) |m| {
            if (!reversed or m.rev) st.applyMode(t, m.*, reversed);
            continue;
        }
        if (reversed) continue;
        if (st.findControlChar(arg)) |c| {
            if (k + 1 >= items.len) return;
            k += 1;
            const v = st.parseControlChar(items[k]) catch continue;
            t.cc[c.index] = v;
            continue;
        }
        if (eql(u8, arg, "ispeed") or eql(u8, arg, "ospeed")) {
            if (k + 1 >= items.len) return;
            k += 1;
            const code = st.speedCode(items[k]) orelse continue;
            if (eql(u8, arg, "ispeed")) st.setInputSpeed(t, code) else st.setOutputSpeed(t, code);
            continue;
        }
        if (eql(u8, arg, "line") or eql(u8, arg, "min") or eql(u8, arg, "time") or
            eql(u8, arg, "rows") or eql(u8, arg, "cols") or eql(u8, arg, "columns"))
        {
            if (k + 1 >= items.len) return;
            k += 1;
            const n = st.parseUnsigned(items[k]) catch continue;
            if (eql(u8, arg, "line") and n <= 255) t.line = @intCast(n);
            if (eql(u8, arg, "min") and n <= 255) t.cc[st.min_index] = @intCast(n);
            if (eql(u8, arg, "time") and n <= 255) t.cc[st.time_index] = @intCast(n);
            continue;
        }
        if (st.looksLikeSave(arg)) {
            t.* = st.parseSave(t.*, arg).?;
            continue;
        }
        if (st.speedCode(arg)) |code| st.setSpeed(t, code);
    }
}

fn expectWholeLines(text: []const u8) !void {
    if (text.len > 0) try std.testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
}

fn show(gpa: std.mem.Allocator, t: st.Termios, ws: ?st.WinSize, cols: usize) !void {
    var a: Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    try st.writeAll(&a.writer, t, ws, cols);
    try expectWholeLines(a.written());
    a.writer.end = 0;
    try st.writeChanged(&a.writer, t, cols);
    try expectWholeLines(a.written());
    a.writer.end = 0;
    try st.writeSave(&a.writer, t);
    const saved = std.mem.trimEnd(u8, a.written(), "\n");
    try std.testing.expect(st.looksLikeSave(saved));
    const back = st.parseSave(.{ .line = t.line }, saved).?;
    try std.testing.expect(st.sameSettings(t, back));
}

fn argvRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var bufs: [8][24]u8 = undefined;
    var items: [8][]const u8 = undefined;
    for (&items, &bufs) |*it, *b| it.* = b[0..smith.slice(b)];
    var t: st.Termios = smith.value(st.Termios);
    const cols = smith.value(u8);
    try show(gpa, t, null, cols);
    applySettings(&t, &items);
    try show(gpa, t, .{ .rows = 24, .cols = 80 }, cols);
    var sane = t;
    applySettings(&sane, &.{"sane"});
    try show(gpa, sane, null, 80);
}

fn textRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var buf: [200]u8 = undefined;
    const text = buf[0..smith.slice(&buf)];
    const base = smith.value(st.Termios);
    _ = st.parseControlChar(text) catch {};
    _ = st.parseUnsigned(text) catch {};
    _ = st.speedCode(text);
    _ = st.findMode(text);
    _ = st.findControlChar(text);
    if (st.parseSave(base, text)) |t| {
        // Whatever parses is shown and saved back the same way.
        try show(gpa, t, null, 40);
        try std.testing.expect(st.looksLikeSave(text));
    }
    var w_buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    // A character with any value is writable in a few bytes or fails cleanly.
    for (text) |c| {
        w.end = 0;
        st.writeChar(&w, c) catch {};
    }
    _ = st.speedBaud(smith.value(u32));
}

const saved_sample = "6d02:5:4bf:8a3b:3:1c:7f:15:4:0:1:0:11:13:1a:0:12:f:17:16:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0";

test "fuzz: stty settings vectors and terminal-state formatting" {
    try engine.fuzz({}, seed_mod.capped(void, argvRun), .{ .name = "stty-argvRun", .corpus = &.{
        seed(.{ "-echo", "intr", "^C", "9600", "sane" }),
        seed(.{ "raw", "-raw", "cooked", "cbreak", "-cbreak", "ek", "evenp", "-oddp" }),
        seed(.{ "ispeed", "38400", "ospeed", "115200", "min", "5", "time", "10", "line", "0x7" }),
        seed(.{ saved_sample, "rows", "40", "cols", "0300" }),
        seed(.{ "erase", "undef", "kill", "^?", "eof", "0377", "werase", "^-", "lnext" }),
        seed(.{ "-", "--", "-icanon", "icanon", "-parenb", "parenb", "cs8", "cs5", "-cs5" }),
        seed(.{ "-ixany", "ixany", "-tabs", "tab3", "crt", "dec", "lcase", "-lcase", "pass8" }),
        seed(.{""}),
    } });
}

test "fuzz: stty values, -g strings and characters" {
    try engine.fuzz({}, seed_mod.capped(void, textRun), .{ .name = "stty-textRun", .corpus = &.{
        seed(.{saved_sample}),
        seed(.{"^C"}),
        seed(.{"0x7f"}),
        seed(.{"18446744073709551616"}),
        seed(.{"134.5"}),
        seed(.{"a:b:c:d"}),
        seed(.{""}),
    } });
}
