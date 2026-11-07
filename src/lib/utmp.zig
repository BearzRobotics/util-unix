// SPDX-License-Identifier: GPL-2.0-or-later
//! The login accounting file (utmp/wtmp), Linux layout.
//!
//! Records are the 384-byte `struct utmp` of glibc and musl on 64-bit and
//! 32-bit Linux (`ut_tv` is two 32-bit integers on every Linux ABI, so the
//! layout does not depend on the word size). Fields are little-endian on the
//! machines this layout was checked on (x86-64); the file is read in the host's
//! byte order, as every other program reading it does.
//!
//! Reference: utmp(5), Linux man-pages.
//!
//! Not supported: systemd-logind sessions (GNU who falls back
//! to them when /var/run/utmp is missing); the BSD utmpx layout.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_path = "/var/run/utmp";
pub const record_size = 384;

pub const Type = enum(i16) {
    empty = 0,
    run_level = 1,
    boot_time = 2,
    new_time = 3,
    old_time = 4,
    init_process = 5,
    login_process = 6,
    user_process = 7,
    dead_process = 8,
    accounting = 9,
    _,
};

/// One record. Text fields are slices into the file contents (not
/// NUL-terminated copies); keep the buffer from `load` alive.
pub const Record = struct {
    kind: Type,
    pid: i32,
    line: []const u8,
    id: []const u8,
    user: []const u8,
    host: []const u8,
    exit_termination: i16,
    exit_status: i16,
    session: i32,
    /// ut_tv.tv_sec as stored (32 bits).
    time: i64,
    /// ut_addr_v6 (IPv4 in the first word).
    addr: [4]u32,
};

fn field(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

/// Decode record `index` of `data`; null past the last whole record.
pub fn record(data: []const u8, index: usize) ?Record {
    const start = std.math.mul(usize, index, record_size) catch return null;
    if (start > data.len or data.len - start < record_size) return null;
    const r = data[start..][0..record_size];
    const endian = builtin.cpu.arch.endian();
    return .{
        .kind = @fromBackingInt(@intCast(std.mem.readInt(i16, r[0..2], endian))),
        .pid = std.mem.readInt(i32, r[4..8], endian),
        .line = field(r[8..40]),
        .id = r[40..44], // not NUL-terminated by definition; trimmed on use
        .user = field(r[44..76]),
        .host = field(r[76..332]),
        .exit_termination = std.mem.readInt(i16, r[332..334], endian),
        .exit_status = std.mem.readInt(i16, r[334..336], endian),
        .session = std.mem.readInt(i32, r[336..340], endian),
        .time = std.mem.readInt(i32, r[340..344], endian),
        .addr = .{
            std.mem.readInt(u32, r[348..352], endian),
            std.mem.readInt(u32, r[352..356], endian),
            std.mem.readInt(u32, r[356..360], endian),
            std.mem.readInt(u32, r[360..364], endian),
        },
    };
}

pub fn count(data: []const u8) usize {
    return data.len / record_size;
}

/// Read a whole utmp-format file. The caller frees the result with `gpa`.
/// A missing default file is an empty list; any other file must exist.
pub fn load(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
}

/// True for a user process whose user name is not empty (GNU `IS_USER_PROCESS`).
pub fn isUserProcess(r: Record) bool {
    return r.kind == .user_process and r.user.len > 0;
}

/// Trim a fixed-width `ut_id` to its meaningful bytes.
pub fn idText(r: Record) []const u8 {
    return field(r.id);
}

test "decoding a hand-built record" {
    var buf: [record_size]u8 = @splat(0);
    const endian = builtin.cpu.arch.endian();
    std.mem.writeInt(i16, buf[0..2], 7, endian);
    std.mem.writeInt(i32, buf[4..8], 4242, endian);
    @memcpy(buf[8..13], "pts/3");
    @memcpy(buf[44..49], "alice");
    @memcpy(buf[76..83], "example");
    std.mem.writeInt(i32, buf[340..344], 1762500000, endian);
    const r = record(&buf, 0).?;
    try std.testing.expectEqual(Type.user_process, r.kind);
    try std.testing.expectEqual(@as(i32, 4242), r.pid);
    try std.testing.expectEqualStrings("pts/3", r.line);
    try std.testing.expectEqualStrings("alice", r.user);
    try std.testing.expectEqualStrings("example", r.host);
    try std.testing.expectEqual(@as(i64, 1762500000), r.time);
    try std.testing.expect(isUserProcess(r));
    try std.testing.expect(record(&buf, 1) == null);
    try std.testing.expect(record(buf[0 .. record_size - 1], 0) == null);
}
