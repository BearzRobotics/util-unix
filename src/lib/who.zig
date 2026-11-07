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
