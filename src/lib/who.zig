// SPDX-License-Identifier: GPL-2.0-or-later
//! who: report who is logged in, from a utmp-format file.
//!
//! References: POSIX.1-2024 who; GNU coreutils 9.7 manual, "who invocation"
//! (the output layout follows GNU's, including its column widths); utmp(5).
//! The source of GNU who was not consulted; the layout was derived by running
//! both programs on synthetic utmp files (test/test_who.sh).
//!
//! Not supported: systemd-logind sessions (GNU who reads them when
//! /var/run/utmp is missing) and `--lookup` (no DNS; the option is accepted
//! and ignored).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utmp = @import("utmp.zig");
const localtime = @import("localtime.zig");
const json = @import("json.zig");

pub const TimeStyle = enum {
    /// `2025-11-07 13:39` (any locale but C/POSIX).
    iso,
    /// `Nov  7 13:39` (C/POSIX locale).
    classic,

    pub fn width(s: TimeStyle) usize {
        return switch (s) {
            .iso => 16,
            .classic => 12,
        };
    }
};

/// Chooses the time style from the locale variables as GNU does in effect:
/// the classic style only for the C/POSIX locale. `lc_all`, `lc_time` and
/// `lang` are the values of those environment variables (null when unset).
pub fn styleForLocale(lc_all: ?[]const u8, lc_time: ?[]const u8, lang: ?[]const u8) TimeStyle {
    const candidates = [_]?[]const u8{ lc_all, lc_time, lang };
    for (candidates) |c| {
        const v = c orelse continue;
        if (v.len == 0) continue;
        if (std.mem.eql(u8, v, "C") or std.mem.eql(u8, v, "POSIX")) return .classic;
        return .iso;
    }
    return .classic;
}

pub const Options = struct {
    // Which records to show (GNU need_*).
    users: bool = false,
    boot: bool = false,
    dead: bool = false,
    login: bool = false,
    init_spawn: bool = false,
    runlevel: bool = false,
    clock_change: bool = false,
    // Columns.
    include_idle: bool = false,
    include_mesg: bool = false,
    include_exit: bool = false,
    /// Short output has no pid column (the default only when no record kind
    /// is selected, see `finish`).
    short: bool = false,
    heading: bool = false,
    /// -q: only the user names and a count.
    count: bool = false,
    /// -m: only the entry for the terminal `my_line` (name without "/dev/");
    /// when `my_line` is null (no terminal) nothing matches.
    my_line_only: bool = false,
    my_line: ?[]const u8 = null,
    style: TimeStyle = .classic,
    /// Current time, seconds since the epoch.
    now: i64,

    /// Defaults once the command line has been read, as GNU does: with no
    /// record kind selected, show the users in short form.
    pub fn finish(o: *Options) void {
        if (!(o.users or o.boot or o.dead or o.login or o.init_spawn or o.runlevel or o.clock_change)) {
            o.users = true;
            o.short = true;
        }
        if (o.include_exit) o.short = false;
    }
};

const Columns = struct {
    user: []const u8 = "",
    state: u8 = ' ',
    line: []const u8 = "",
    time: []const u8 = "",
    idle: []const u8 = "",
    pid: []const u8 = "",
    comment: []const u8 = "",
    exit: []const u8 = "",
};

fn printLine(w: *Io.Writer, o: Options, c: Columns) Io.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    var f: Io.Writer = .fixed(&buf);
    // The record's strings are bounded by the utmp field sizes, so this fits.
    printLineTo(&f, o, c) catch return error.WriteFailed;
    const text = std.mem.trimEnd(u8, f.buffered(), " ");
    try w.writeAll(text);
    try w.writeByte('\n');
}

fn printLineTo(f: *Io.Writer, o: Options, c: Columns) Io.Writer.Error!void {
    try f.print("{s:<8}", .{c.user});
    if (o.include_mesg) try f.print(" {c}", .{c.state});
    try f.print(" {s:<12}", .{c.line});
    try f.print(" {s:<[1]}", .{ c.time, o.style.width() });
    if (!o.short) {
        if (o.include_idle) try f.print(" {s:<6}", .{c.idle});
        try f.print(" {s:>10}", .{c.pid});
    }
    try f.print(" {s:<8}", .{c.comment});
    if (o.include_exit) try f.print(" {s}", .{c.exit});
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Format `ts` for the time column into `buf`.
pub fn formatTime(buf: []u8, style: TimeStyle, zone: *const localtime.Zone, ts: i64) []const u8 {
    const l = zone.local(ts);
    const text = switch (style) {
        .iso => std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(@max(l.year, 0))), l.month, l.day, l.hour, l.minute,
        }),
        .classic => std.fmt.bufPrint(buf, "{s} {d:>2} {d:0>2}:{d:0>2}", .{ months[l.month - 1], l.day, l.hour, l.minute }),
    };
    return text catch buf[0..0];
}

/// Idle column for a terminal last used at `last` (GNU: `.` for under a minute,
/// `HH:MM` up to a day, `old` beyond; `?` when unknown). `boot` is the time
/// of the last boot record read so far.
pub fn idleText(buf: []u8, last: ?i64, now: i64, boot: i64) []const u8 {
    const when = last orelse return "  ?";
    if (boot < when and when <= now) {
        const idle = now - when;
        if (idle < 60) return "  .  ";
        if (idle < 24 * 3600) {
            return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(idle, 3600))), @as(u64, @intCast(@divFloor(@mod(idle, 3600), 60))) }) catch "";
        }
    }
    return " old ";
}

/// Terminal facts used by `who`/`pinky`: group-writability and the last
/// access time of /dev/LINE.
pub const TtyInfo = struct {
    /// 0o020 (group write) set; false when the terminal cannot be examined.
    group_writable: bool,
    atime: ?i64,
    exists: bool,
};

pub fn ttyInfo(io: Io, line: []const u8) TtyInfo {
    var path_buf: [300]u8 = undefined;
    const path = if (std.mem.startsWith(u8, line, "/dev/"))
        std.fmt.bufPrint(&path_buf, "{s}", .{line}) catch return .{ .group_writable = false, .atime = null, .exists = false }
    else
        std.fmt.bufPrint(&path_buf, "/dev/{s}", .{line}) catch return .{ .group_writable = false, .atime = null, .exists = false };
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .group_writable = false, .atime = null, .exists = false };
    const mode: u32 = @backingInt(st.permissions);
    return .{
        .group_writable = mode & 0o020 != 0,
        .atime = if (st.atime) |a| a.toSeconds() else null,
        .exists = true,
    };
}

/// Write the report for the utmp-format `data`.
pub fn write(io: Io, w: *Io.Writer, data: []const u8, zone: *const localtime.Zone, o: Options) Io.Writer.Error!void {
    if (o.count) return writeCount(w, data);
    if (o.heading) {
        try printLine(w, o, .{ .user = "NAME", .line = "LINE", .time = "TIME", .idle = "IDLE", .pid = "PID", .comment = "COMMENT", .exit = "EXIT" });
    }
    var boot: i64 = 0;
    var tbuf: [64]u8 = undefined;
    var ibuf: [32]u8 = undefined;
    var pbuf: [32]u8 = undefined;
    var cbuf: [64]u8 = undefined;
    var xbuf: [64]u8 = undefined;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        const time = formatTime(&tbuf, o.style, zone, r.time);
        switch (r.kind) {
            .user_process => {
                if (!o.users or !utmp.isUserProcess(r)) continue;
                if (o.my_line_only) {
                    const mine = o.my_line orelse continue;
                    const rl = if (std.mem.startsWith(u8, r.line, "/dev/")) r.line[5..] else r.line;
                    if (!std.mem.eql(u8, rl, mine)) continue;
                }
                const info = ttyInfo(io, r.line);
                const state: u8 = if (!info.exists) '?' else if (info.group_writable) '+' else '-';
                const idle = idleText(&ibuf, info.atime, o.now, boot);
                const host = if (r.host.len > 0) std.fmt.bufPrint(&cbuf, "({s})", .{r.host}) catch "" else "";
                try printLine(w, o, .{
                    .user = r.user,
                    .state = state,
                    .line = r.line,
                    .time = time,
                    .idle = idle,
                    .pid = std.fmt.bufPrint(&pbuf, "{d}", .{r.pid}) catch "",
                    .comment = host,
                });
            },
            .boot_time => {
                boot = r.time;
                if (o.boot) try printLine(w, o, .{ .line = "system boot", .time = time });
            },
            .new_time => if (o.clock_change) try printLine(w, o, .{ .line = "clock change", .time = time }),
            .run_level => if (o.runlevel) {
                const raw: u32 = @bitCast(r.pid);
                const current: u8 = @truncate(raw);
                const last: u8 = @truncate(raw >> 8);
                const line = std.fmt.bufPrint(&xbuf, "run-level {c}", .{current}) catch "";
                const comment = if (last != 0) std.fmt.bufPrint(&cbuf, "last={c}", .{last}) catch "" else "";
                try printLine(w, o, .{ .line = line, .time = time, .comment = comment });
            },
            .init_process => if (o.init_spawn) {
                const comment = std.fmt.bufPrint(&cbuf, "id={s}", .{utmp.idText(r)}) catch "";
                try printLine(w, o, .{ .line = r.line, .time = time, .pid = std.fmt.bufPrint(&pbuf, "{d}", .{r.pid}) catch "", .comment = comment });
            },
            .login_process => if (o.login) {
                const comment = std.fmt.bufPrint(&cbuf, "id={s}", .{utmp.idText(r)}) catch "";
                try printLine(w, o, .{ .user = "LOGIN", .line = r.line, .time = time, .pid = std.fmt.bufPrint(&pbuf, "{d}", .{r.pid}) catch "", .comment = comment });
            },
            .dead_process => if (o.dead) {
                const comment = std.fmt.bufPrint(&cbuf, "id={s}", .{utmp.idText(r)}) catch "";
                const exit = std.fmt.bufPrint(&xbuf, "term={d} exit={d}", .{ r.exit_termination, r.exit_status }) catch "";
                try printLine(w, o, .{ .line = r.line, .time = time, .pid = std.fmt.bufPrint(&pbuf, "{d}", .{r.pid}) catch "", .comment = comment, .exit = exit });
            },
            else => {},
        }
    }
}

/// True when `write` would print record `r` for these options. `boot` is not
/// needed: only user records depend on it, for the idle column, not selection.
fn selected(o: Options, r: utmp.Record) bool {
    return switch (r.kind) {
        .user_process => o.users and utmp.isUserProcess(r) and blk: {
            if (!o.my_line_only) break :blk true;
            const mine = o.my_line orelse break :blk false;
            const rl = if (std.mem.startsWith(u8, r.line, "/dev/")) r.line[5..] else r.line;
            break :blk std.mem.eql(u8, rl, mine);
        },
        .boot_time => o.boot,
        .new_time => o.clock_change,
        .run_level => o.runlevel,
        .init_process => o.init_spawn,
        .login_process => o.login,
        .dead_process => o.dead,
        else => false,
    };
}

fn kindName(k: utmp.Type) []const u8 {
    return switch (k) {
        .user_process => "user",
        .boot_time => "boot",
        .new_time => "clock_change",
        .run_level => "run_level",
        .init_process => "init",
        .login_process => "login",
        .dead_process => "dead",
        else => "other",
    };
}

/// Write the records `write` would print as one JSON array, one object per
/// line (decision 0007). Column options (heading, short, idle) do not apply.
/// Every record has type, user, line, id, pid, host and time (seconds since
/// the epoch, UTC); user records add `mesg` ("+", "-" or "?"), dead records
/// add exit_termination and exit_status, run-level records add `runlevel` and
/// `previous`. With `o.count` the result is {"users":[...],"count":n}.
pub fn writeJson(io: Io, w: *Io.Writer, data: []const u8, o: Options) Io.Writer.Error!void {
    if (o.count) return writeCountJson(w, data);
    try w.writeByte('[');
    var n: usize = 0;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        if (!selected(o, r)) continue;
        try w.writeAll(if (n == 0) "\n" else ",\n");
        n += 1;
        try w.print("{{\"type\":\"{s}\",\"user\":", .{kindName(r.kind)});
        try json.writeString(w, r.user);
        try w.writeAll(",\"line\":");
        try json.writeString(w, r.line);
        try w.writeAll(",\"id\":");
        try json.writeString(w, utmp.idText(r));
        try w.print(",\"pid\":{d},\"host\":", .{r.pid});
        try json.writeString(w, r.host);
        try w.print(",\"time\":{d}", .{r.time});
        switch (r.kind) {
            .user_process => {
                const info = ttyInfo(io, r.line);
                const state: []const u8 = if (!info.exists) "?" else if (info.group_writable) "+" else "-";
                try w.print(",\"mesg\":\"{s}\"", .{state});
            },
            .dead_process => try w.print(",\"exit_termination\":{d},\"exit_status\":{d}", .{ r.exit_termination, r.exit_status }),
            .run_level => {
                const raw: u32 = @bitCast(r.pid);
                const current: u8 = @truncate(raw);
                const last: u8 = @truncate(raw >> 8);
                try w.print(",\"runlevel\":\"{c}\",\"previous\":", .{current});
                if (last != 0) try w.print("\"{c}\"", .{last}) else try w.writeAll("null");
            },
            else => {},
        }
        try w.writeByte('}');
    }
    try w.writeAll(if (n == 0) "]\n" else "\n]\n");
}

fn writeCountJson(w: *Io.Writer, data: []const u8) Io.Writer.Error!void {
    try w.writeAll("{\"users\":[");
    var n: usize = 0;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        if (!utmp.isUserProcess(r)) continue;
        if (n > 0) try w.writeByte(',');
        try json.writeString(w, r.user);
        n += 1;
    }
    try w.print("],\"count\":{d}}}\n", .{n});
}

fn writeCount(w: *Io.Writer, data: []const u8) Io.Writer.Error!void {
    var n: usize = 0;
    var i: usize = 0;
    while (utmp.record(data, i)) |r| : (i += 1) {
        if (!utmp.isUserProcess(r)) continue;
        if (n > 0) try w.writeByte(' ');
        try w.writeAll(r.user);
        n += 1;
    }
    try w.print("\n# users={d}\n", .{n});
}

test "locale selects the time style" {
    const t = std.testing;
    try t.expectEqual(TimeStyle.classic, styleForLocale(null, null, null));
    try t.expectEqual(TimeStyle.classic, styleForLocale("C", null, "en_US.UTF-8"));
    try t.expectEqual(TimeStyle.classic, styleForLocale("POSIX", null, null));
    try t.expectEqual(TimeStyle.iso, styleForLocale(null, null, "en_US.UTF-8"));
    try t.expectEqual(TimeStyle.iso, styleForLocale("", null, "C.UTF-8"));
}

test "idle text" {
    var buf: [16]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("  ?", idleText(&buf, null, 1000, 0));
    try t.expectEqualStrings("  .  ", idleText(&buf, 990, 1000, 0));
    try t.expectEqualStrings("01:01", idleText(&buf, 1000, 1000 + 3661, 0));
    try t.expectEqualStrings(" old ", idleText(&buf, 1000, 1000 + 86400 + 5, 0));
    try t.expectEqualStrings(" old ", idleText(&buf, 100, 1000, 500)); // before the boot
}

test "time formats" {
    var zone: localtime.Zone = .{};
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2025-11-07 12:34", formatTime(&buf, .iso, &zone, 1762518896));
    try std.testing.expectEqualStrings("Nov  7 12:34", formatTime(&buf, .classic, &zone, 1762518896));
}

fn testRecord(buf: []u8, index: usize, kind: i16, user: []const u8, line: []const u8, time: i32) void {
    const endian = @import("builtin").cpu.arch.endian();
    const r = buf[index * utmp.record_size ..][0..utmp.record_size];
    @memset(r, 0);
    std.mem.writeInt(i16, r[0..2], kind, endian);
    std.mem.writeInt(i32, r[4..8], 99, endian);
    @memcpy(r[8..][0..line.len], line);
    @memcpy(r[44..][0..user.len], user);
    std.mem.writeInt(i32, r[340..344], time, endian);
}

test "json: selects the same records as write and escapes text" {
    var data: [3 * utmp.record_size]u8 = undefined;
    testRecord(&data, 0, 2, "", "~", 100); // boot
    testRecord(&data, 1, 7, "al\"ice", "pts/9", 200); // user (tty does not exist: mesg ?)
    testRecord(&data, 2, 8, "", "pts/1", 300); // dead
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(std.testing.io, &w, &data, .{ .users = true, .now = 0 });
    try std.testing.expectEqualStrings(
        "[\n{\"type\":\"user\",\"user\":\"al\\\"ice\",\"line\":\"pts/9\",\"id\":\"\",\"pid\":99,\"host\":\"\",\"time\":200,\"mesg\":\"?\"}\n]\n",
        w.buffered(),
    );
    var w2: Io.Writer = .fixed(&buf);
    try writeJson(std.testing.io, &w2, &data, .{ .boot = true, .dead = true, .now = 0 });
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"type\":\"boot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"exit_status\":0") != null);
    var w3: Io.Writer = .fixed(&buf);
    try writeJson(std.testing.io, &w3, &data, .{ .runlevel = true, .now = 0 });
    try std.testing.expectEqualStrings("[]\n", w3.buffered());
}

test "json: -q form" {
    var data: [2 * utmp.record_size]u8 = undefined;
    testRecord(&data, 0, 7, "bob", "pts/1", 1);
    testRecord(&data, 1, 7, "eve", "pts/2", 2);
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(std.testing.io, &w, &data, .{ .count = true, .now = 0 });
    try std.testing.expectEqualStrings("{\"users\":[\"bob\",\"eve\"],\"count\":2}\n", w.buffered());
}
