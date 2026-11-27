// SPDX-License-Identifier: GPL-2.0-or-later
//! The POSIX form of a time zone rule, as in TZ="EST5EDT,M3.2.0,M11.1.0" and
//! in the last line of a TZif file, which says what holds after the file's
//! last listed change.
//!
//!     std offset [ dst [offset] [ ,start[/time],end[/time] ] ]
//!
//! A name is three or more letters, or "<...>" with digits and signs too. An
//! offset is [+-]hh[:mm[:ss]], positive *west* of Greenwich. start and end are
//! Jn (day 1-365, 29 February not counted), n (day 0-365) or Mm.w.d (week w
//! of month m, 5 meaning the last, weekday d from Sunday); time is the local
//! time of the change, 02:00 by default (RFC 8536 allows -167 to 167 hours).
//! A rule with a dst name and no dates uses those of the United States, as
//! glibc does.
//!
//! References: POSIX.1-2024 XBD 8.3 (TZ); RFC 8536 3.3.1.

const std = @import("std");

const Day = union(enum) {
    julian: u16, // 1-365, 29 February never counted
    ordinal: u16, // 0-365, counted
    weekday: struct { month: u8, week: u8, day: u8 },
};

const Change = struct { day: Day, seconds: i32 = 2 * 3600 };

const Daylight = struct { offset: i32, start: Change, end: Change };

pub const Rule = struct {
    /// Seconds east of UTC outside daylight saving time.
    standard: i32,
    daylight: ?Daylight = null,

    /// Seconds east of UTC at `ts` (seconds since the epoch).
    pub fn offsetAt(rule: Rule, ts: i64) i32 {
        const dst = rule.daylight orelse return rule.standard;
        // far beyond any calendar of use, and safe from overflow
        const t = std.math.clamp(ts, -(1 << 50), 1 << 50);
        const year = yearOf(@divFloor(t, 86400));
        // each change is given in the time in force before it
        const start = at(year, dst.start) - rule.standard;
        const end = at(year, dst.end) - dst.offset;
        const in_force = if (start <= end) t >= start and t < end else t >= start or t < end;
        return if (in_force) dst.offset else rule.standard;
    }
};

/// The local time of `change` in `year`, as seconds since the epoch.
fn at(year: i64, change: Change) i64 {
    const first = daysFrom(year, 1, 1);
    const days: i64 = switch (change.day) {
        .julian => |n| first + n - 1 + @intFromBool(isLeap(year) and n >= 60),
        .ordinal => |n| first + n,
        .weekday => |w| blk: {
            const month_first = daysFrom(year, w.month, 1);
            const first_weekday: i64 = @mod(month_first + 4, 7); // day 0 was a Thursday
            var d: i64 = 1 + @mod(w.day - first_weekday, 7) + 7 * (@as(i64, w.week) - 1);
            if (d > monthLength(year, w.month)) d -= 7;
            break :blk month_first + d - 1;
        },
    };
    return days * 86400 + change.seconds;
}

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthLength(year: i64, month: u8) i64 {
    return switch (month) {
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 31,
    };
}

/// Days from 1970-01-01 (Howard Hinnant's days_from_civil).
fn daysFrom(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn yearOf(days: i64) i64 {
    var year = 1970 + @divFloor(days * 400, 146097);
    while (daysFrom(year, 1, 1) > days) year -= 1;
    while (daysFrom(year + 1, 1, 1) <= days) year += 1;
    return year;
}

/// Parse a rule; null when `text` is not one.
pub fn parse(text: []const u8) ?Rule {
    var p: Parser = .{ .text = text };
    return p.rule();
}

const Parser = struct {
    text: []const u8,
    i: usize = 0,

    fn peek(p: *const Parser) u8 {
        return if (p.i < p.text.len) p.text[p.i] else 0;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() != c) return false;
        p.i += 1;
        return true;
    }

    fn rule(p: *Parser) ?Rule {
        if (!p.name()) return null;
        var r: Rule = .{ .standard = -(p.time(24) orelse return null) };
        if (p.i == p.text.len) return r;
        if (!p.name()) return null;
        var dst: Daylight = .{
            .offset = r.standard + 3600,
            .start = .{ .day = .{ .weekday = .{ .month = 3, .week = 2, .day = 0 } } },
            .end = .{ .day = .{ .weekday = .{ .month = 11, .week = 1, .day = 0 } } },
        };
        if (p.i < p.text.len and p.peek() != ',') dst.offset = -(p.time(24) orelse return null);
        if (p.i < p.text.len) {
            if (!p.eat(',')) return null;
            dst.start = p.change() orelse return null;
            if (!p.eat(',')) return null;
            dst.end = p.change() orelse return null;
        }
        if (p.i != p.text.len) return null;
        r.daylight = dst;
        return r;
    }

    fn name(p: *Parser) bool {
        const quoted = p.eat('<');
        const start = p.i;
        while (std.ascii.isAlphabetic(p.peek()) or (quoted and (std.ascii.isDigit(p.peek()) or p.peek() == '+' or p.peek() == '-'))) p.i += 1;
        const long_enough = p.i - start >= 3;
        if (quoted and !p.eat('>')) return false;
        return long_enough;
    }

    /// Up to three digits, no more than `max`.
    fn number(p: *Parser, max: u32) ?u32 {
        var v: u32 = 0;
        var n: usize = 0;
        while (n < 3 and std.ascii.isDigit(p.peek())) : (n += 1) {
            v = v * 10 + (p.peek() - '0');
            p.i += 1;
        }
        return if (n == 0 or v > max) null else v;
    }

    /// [+-]hh[:mm[:ss]] in seconds.
    fn time(p: *Parser, max_hours: u32) ?i32 {
        const negative = p.eat('-');
        if (!negative) _ = p.eat('+');
        var seconds: i32 = @intCast((p.number(max_hours) orelse return null) * 3600);
        if (p.eat(':')) {
            seconds += @intCast((p.number(59) orelse return null) * 60);
            if (p.eat(':')) seconds += @intCast(p.number(59) orelse return null);
        }
        return if (negative) -seconds else seconds;
    }

    fn change(p: *Parser) ?Change {
        const day: Day = if (p.eat('J')) blk: {
            const n = p.number(365) orelse return null;
            if (n == 0) return null;
            break :blk .{ .julian = @intCast(n) };
        } else if (p.eat('M')) blk: {
            const month = p.number(12) orelse return null;
            if (!p.eat('.')) return null;
            const week = p.number(5) orelse return null;
            if (!p.eat('.')) return null;
            const weekday = p.number(6) orelse return null;
            if (month == 0 or week == 0) return null;
            break :blk .{ .weekday = .{ .month = @intCast(month), .week = @intCast(week), .day = @intCast(weekday) } };
        } else .{ .ordinal = @intCast(p.number(365) orelse return null) };
        var c: Change = .{ .day = day };
        if (p.eat('/')) c.seconds = p.time(167) orelse return null;
        return c;
    }
};

const testing = std.testing;

test "fixed offsets" {
    try testing.expectEqual(@as(i32, 9 * 3600), parse("JST-9").?.offsetAt(0));
    try testing.expectEqual(@as(i32, 3 * 3600 + 1800), parse("<+0330>-3:30").?.offsetAt(0));
    try testing.expectEqual(@as(i32, -5 * 3600), parse("EST5").?.offsetAt(1700000000));
    for ([_][]const u8{ "", "JS-9", "JST", "JST-", "JST-25", "EST5EDT,", "EST5EDT,M3.2.0", "EST5EDT,M13.1.0,M11.1.0", "EST5EDT,J0,J1", "EST5 ", "<ab>1", "No/Such_Zone" }) |bad| {
        try testing.expect(parse(bad) == null);
    }
}

test "daylight saving, north and south" {
    const us = parse("EST5EDT,M3.2.0,M11.1.0").?;
    // 2023: clocks changed 12 March 07:00 and 5 November 06:00 UTC
    try testing.expectEqual(@as(i32, -5 * 3600), us.offsetAt(1678604399));
    try testing.expectEqual(@as(i32, -4 * 3600), us.offsetAt(1678604400));
    try testing.expectEqual(@as(i32, -4 * 3600), us.offsetAt(1699163999));
    try testing.expectEqual(@as(i32, -5 * 3600), us.offsetAt(1699164000));
    try testing.expectEqual(parse("EST5EDT").?.offsetAt(1678604400), us.offsetAt(1678604400));
    const south = parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try testing.expectEqual(@as(i32, 11 * 3600), south.offsetAt(1700000000)); // November
    try testing.expectEqual(@as(i32, 10 * 3600), south.offsetAt(1688000000)); // June
    _ = us.offsetAt(std.math.maxInt(i64));
    _ = us.offsetAt(std.math.minInt(i64));
}

test "days and years" {
    try testing.expectEqual(@as(i64, 0), daysFrom(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11016), daysFrom(2000, 2, 29));
    try testing.expectEqual(@as(i64, 1999), yearOf(daysFrom(1999, 12, 31)));
    try testing.expectEqual(@as(i64, 2100), yearOf(daysFrom(2100, 1, 1)));
}
