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
        var reader: Io.Reader = .fixed(data);
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
        var l = civil(ts + off);
        l.offset = off;
        return l;
    }
};

/// Calendar fields of `secs` seconds since 1970-01-01 00:00:00 (proleptic
/// Gregorian, no offset applied).
pub fn civil(secs: i64) Local {
    const days = @divFloor(secs, 86400);
    const rem: u32 = @intCast(@mod(secs, 86400));
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
