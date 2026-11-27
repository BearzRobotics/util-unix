// SPDX-License-Identifier: GPL-2.0-or-later
//! Local calendar time from a time zone database file (TZif, RFC 8536).
//!
//! Used by who and pinky, which print login times in local
//! time. The zone comes from the TZ value the caller passes (null means the
//! variable is unset), else /etc/localtime:
//!
//! - unset: /etc/localtime
//! - "" (empty), "UTC", "UTC0", "GMT": UTC
//! - ":NAME" or "NAME" with a file /usr/share/zoneinfo/NAME, or an absolute path
//!
//! POSIX rule strings such as "EST5EDT,M3.2.0,M11.1.0" and the footer rule of
//! the TZif file are not interpreted: an instant after the last stored
//! transition keeps the last transition's offset, and an unreadable or unknown
//! zone is UTC. Standard zoneinfo files built "fat" (Debian's) carry
//! transitions up to 2037, so this matters only for unusual setups.
//!
//! The std parser trusts the record counts and leap-second values in the file,
//! so a damaged or hostile one (TZ may name any file) could make it overflow or
//! allocate gigabytes. The counts are checked against the file's size first,
//! and the leap-second records, which nothing here uses, are removed.
//!
//! References: tzfile(5); Zig std.tz for the file parser.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Local = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
    /// 0 = Sunday.
    weekday: u8,
    /// Seconds east of UTC.
    offset: i32,
};

pub const Zone = struct {
    tz: ?std.tz.Tz = null,

    pub fn deinit(z: *Zone) void {
        if (z.tz) |*t| t.deinit();
        z.tz = null;
    }

    /// Load the zone selected by `tz_env`; falls back to UTC.
    pub fn load(io: Io, gpa: Allocator, tz_env: ?[]const u8) Zone {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path: []const u8 = blk: {
            const raw = tz_env orelse break :blk "/etc/localtime";
            var name = raw;
            if (name.len > 0 and name[0] == ':') name = name[1..];
            if (name.len == 0) return .{};
            if (std.mem.eql(u8, name, "UTC") or std.mem.eql(u8, name, "UTC0") or std.mem.eql(u8, name, "GMT")) return .{};
            if (name[0] == '/') break :blk name;
            break :blk std.fmt.bufPrint(&path_buf, "/usr/share/zoneinfo/{s}", .{name}) catch return .{};
        };
        // A zone name must stay inside the zoneinfo tree.
        if (std.mem.indexOf(u8, path, "/../") != null) return .{};
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return .{};
        defer gpa.free(data);
        return parse(gpa, data);
    }

    /// The zone in the TZif file `data`, which is changed on the way; UTC when
    /// it is not a usable one.
    fn parse(gpa: Allocator, data: []u8) Zone {
        const usable = prepare(data) orelse return .{};
        var reader: Io.Reader = .fixed(usable);
        const tz = std.tz.Tz.parse(gpa, &reader) catch return .{};
        return .{ .tz = tz };
    }

    /// UTC offset in effect at `ts` (seconds since the epoch).
    pub fn offsetAt(z: *const Zone, ts: i64) i32 {
        const tz = z.tz orelse return 0;
        const trans = tz.transitions;
        if (trans.len == 0 or ts < trans[0].ts) {
            // Before the first transition: the first standard-time type.
            for (tz.timetypes) |t| if (!t.isDst()) return t.offset;
            return tz.timetypes[0].offset;
        }
        var lo: usize = 0;
        var hi: usize = trans.len; // trans[lo].ts <= ts < trans[hi].ts
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (trans[mid].ts <= ts) lo = mid else hi = mid;
        }
        return trans[lo].timetype.offset;
    }

    pub fn local(z: *const Zone, ts: i64) Local {
        const off = z.offsetAt(ts);
        var l = civil(ts +| off);
        l.offset = off;
        return l;
    }
};

const header_len = 44;
/// Where the leap-second count is in a header.
const leapcnt_at = 28;

const Block = struct {
    /// Bytes before the leap-second records, after them, and the records'.
    before: u64,
    leaps: u64,
    after: u64,
};

/// The sizes of the data that the TZif header at the start of `data` announces,
/// with transition times of `time_size` bytes. Null unless all of it is there.
fn block(data: []const u8, time_size: u64) ?Block {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    var counts: [6]u64 = undefined;
    for (&counts, 0..) |*c, i| c.* = std.mem.readInt(u32, data[20 + 4 * i ..][0..4], .big);
    const isutcnt, const isstdcnt, const leapcnt, const timecnt, const typecnt, const charcnt = counts;
    // 32-bit counts and small factors: none of this overflows 64 bits
    const b: Block = .{
        .before = timecnt * (time_size + 1) + typecnt * 6 + charcnt,
        .leaps = leapcnt * (time_size + 4),
        .after = isstdcnt + isutcnt,
    };
    if (b.before + b.leaps + b.after > data.len - header_len) return null;
    return b;
}

/// Check the counts of the TZif file `data` and take out the leap-second
/// records of the block that will be read. Returns what to parse, or null.
fn prepare(data: []u8) ?[]u8 {
    var at: usize = 0;
    var time_size: u64 = 4;
    const first = block(data, time_size) orelse return null;
    if (data[4] != 0) {
        // a version 1 block, which is skipped, then the one with 64-bit times
        at = header_len + @as(usize, @intCast(first.before + first.leaps + first.after));
        time_size = 8;
    }
    const b = block(data[at..], time_size) orelse return null;
    const leaps_at = at + header_len + @as(usize, @intCast(b.before));
    const leaps: usize = @intCast(b.leaps);
    @memmove(data[leaps_at .. data.len - leaps], data[leaps_at + leaps ..]);
    @memset(data[at + leapcnt_at ..][0..4], 0);
    return data[0 .. data.len - leaps];
}

/// The seconds `civil` can represent: the year must fit its field.
const civil_limit = 1 << 55;

/// Calendar fields of `secs` seconds since 1970-01-01 00:00:00 (proleptic
/// Gregorian, no offset applied).
pub fn civil(secs: i64) Local {
    // further than a billion years either way is given as that
    const s = std.math.clamp(secs, -civil_limit, civil_limit);
    const days = @divFloor(s, 86400);
    const rem: u32 = @intCast(@mod(s, 86400));
    // Howard Hinnant's civil_from_days.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = m,
        .day = d,
        .hour = @intCast(rem / 3600),
        .minute = @intCast(rem % 3600 / 60),
        .second = @intCast(rem % 60),
        .weekday = @intCast(@mod(days + 4, 7)),
        .offset = 0,
    };
}

test "civil converts known instants" {
    const t = std.testing;
    const a = civil(0);
    try t.expectEqual(@as(i32, 1970), a.year);
    try t.expectEqual(@as(u8, 1), a.month);
    try t.expectEqual(@as(u8, 4), a.weekday); // Thursday
    // 2025-11-07 12:34:56 UTC is a Friday.
    const b = civil(1762518896);
    try t.expectEqual(@as(i32, 2025), b.year);
    try t.expectEqual(@as(u8, 11), b.month);
    try t.expectEqual(@as(u8, 7), b.day);
    try t.expectEqual(@as(u8, 12), b.hour);
    try t.expectEqual(@as(u8, 34), b.minute);
    try t.expectEqual(@as(u8, 56), b.second);
    try t.expectEqual(@as(u8, 5), b.weekday);
    // Before the epoch and on a leap day.
    const c = civil(-1);
    try t.expectEqual(@as(i32, 1969), c.year);
    try t.expectEqual(@as(u8, 12), c.month);
    try t.expectEqual(@as(u8, 31), c.day);
    const d = civil(951782400); // 2000-02-29
    try t.expectEqual(@as(u8, 29), d.day);
    try t.expectEqual(@as(u8, 2), d.month);
}

test "UTC zone has offset 0 and an unknown name falls back to UTC" {
    var z = Zone.load(std.testing.io, std.testing.allocator, "UTC");
    defer z.deinit();
    try std.testing.expectEqual(@as(i32, 0), z.offsetAt(1762518896));
    var u = Zone.load(std.testing.io, std.testing.allocator, "No/Such_Zone");
    defer u.deinit();
    try std.testing.expectEqual(@as(i32, 0), u.offsetAt(0));
}

/// A TZif header for a test: counts in file order.
fn testHeader(version: u8, counts: [6]u32) [header_len]u8 {
    var h: [header_len]u8 = @splat(0);
    @memcpy(h[0..4], "TZif");
    h[4] = version;
    for (counts, 0..) |c, i| std.mem.writeInt(u32, h[20 + 4 * i ..][0..4], c, .big);
    return h;
}

test "counts larger than the file are refused before parsing" {
    const t = std.testing;
    const huge = std.math.maxInt(u32);
    for ([_][6]u32{
        .{ 0, 0, 0, huge, 1, 4 },
        .{ 0, 0, huge, 0, 1, 4 },
        .{ 0, 0, 0, 0, huge, 4 },
        .{ huge, huge, 0, 0, 1, 4 },
        .{ 0, 0, 0, 0x04000000, 1, 4 },
    }) |counts| {
        for ([_]u8{ 0, '2' }) |version| {
            // as the first header, and as the second
            var one = testHeader(version, counts) ++ @as([10]u8, @splat(0));
            var z = Zone.parse(t.failing_allocator, &one);
            try t.expect(z.tz == null);
            var two = testHeader('2', @splat(0)) ++ testHeader('2', counts) ++ @as([10]u8, @splat(0));
            z = Zone.parse(t.failing_allocator, &two);
            try t.expect(z.tz == null);
        }
    }
}

test "leap-second records are not given to the parser" {
    const t = std.testing;
    const be = struct {
        fn int(comptime T: type, v: T) [@sizeOf(T)]u8 {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .big);
            return b;
        }
    };
    // one zone, an hour east, with two leap records whose times and
    // corrections overflow the std parser's arithmetic
    const zone = be.int(i32, 3600) ++ [2]u8{ 0, 0 } ++ "ABC\x00".*;
    const far: i64 = (1 << 47) - 1;
    const leaps = be.int(i64, far) ++ be.int(i32, 1) ++ be.int(i64, far) ++ be.int(i32, std.math.maxInt(i32));
    var data = testHeader('2', @splat(0)) ++ testHeader('2', .{ 0, 0, 2, 0, 1, 4 }) ++ zone ++ leaps ++ "\n\n".*;
    var z = Zone.parse(t.allocator, &data);
    defer z.deinit();
    try t.expectEqual(@as(i32, 3600), z.offsetAt(0));

    // version 1: 32-bit times, no second header
    const old_leaps = be.int(i32, 0) ++ be.int(i32, 1) ++ be.int(i32, 3000000) ++ be.int(i32, std.math.maxInt(i32));
    var old = testHeader(0, .{ 0, 0, 2, 0, 1, 4 }) ++ zone ++ old_leaps;
    var y = Zone.parse(t.allocator, &old);
    defer y.deinit();
    try t.expectEqual(@as(i32, 3600), y.offsetAt(0));
}

test "any time has a calendar date" {
    _ = civil(std.math.maxInt(i64));
    _ = civil(std.math.minInt(i64));
    var z: Zone = .{};
    _ = z.local(std.math.maxInt(i64));
}
