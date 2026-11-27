// SPDX-License-Identifier: GPL-2.0-or-later
//! The login accounting file (utmp/wtmp), Linux layout.
//!
//! The size of `struct utmp` depends on the architecture. Where glibc keeps the
//! 32-bit layout of its time fields (`__WORDSIZE_TIME64_COMPAT32`: x86-64,
//! RISC-V 64, PowerPC 64, and every 32-bit one) a record is 384 bytes, with a
//! 32-bit session id and seconds. On AArch64, LoongArch 64 and s390x those are
//! 64-bit and a record is 400 bytes. What matters is the program that wrote
//! the file, which is the system's glibc tools whatever this one is built with:
//! musl keeps no utmp of its own. The file is read in the host's byte order, as
//! every other program reading it does.
//!
//! Reference: utmp(5), Linux man-pages.
//!
//! Not supported: systemd-logind sessions (GNU who falls back
//! to them when /var/run/utmp is missing); the BSD utmpx layout.

const std = @import("std");

/// Bytes in the remote host field (`ut_host`).
pub const host_size = 256;
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_path = "/var/run/utmp";
/// Where the architecture-dependent fields are; those before them do not move.
pub const Layout = struct {
    size: usize,
    /// The session id and the seconds are 64-bit.
    wide: bool,

    pub const compat: Layout = .{ .size = 384, .wide = false };
    pub const wide64: Layout = .{ .size = 400, .wide = true };

    pub fn of(arch: std.Target.Cpu.Arch) Layout {
        return switch (arch) {
            .aarch64, .aarch64_be, .loongarch64, .s390x => wide64,
            else => compat,
        };
    }
};

/// The layout of the system this is built for.
pub const native = Layout.of(builtin.cpu.arch);
pub const record_size = native.size;

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
    /// ut_tv.tv_sec as stored.
    time: i64,
    /// ut_addr_v6 (IPv4 in the first word).
    addr: [4]u32,
};

/// Replace the control characters in `text` with '?', for showing it on a
/// terminal, which would obey them: C0 and DEL, C1 as UTF-8 (two '?') or as a
/// lone byte. Other bytes stay. With `layout`, tabs, newlines and the carriage
/// return of a "\r\n" stay too. The length does not change.
pub fn maskControls(text: []u8, layout: bool) void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            const keep = layout and (c == '\n' or c == '\t' or (c == '\r' and i + 1 < text.len and text[i + 1] == '\n'));
            if ((c < 0x20 and !keep) or c == 0x7f) text[i] = '?';
            i += 1;
            continue;
        }
        const n: usize = std.unicode.utf8ByteSequenceLength(c) catch 0;
        const cp: ?u21 = if (n == 0 or n > text.len - i) null else std.unicode.utf8Decode(text[i..][0..n]) catch null;
        if (cp) |p| {
            if (p < 0xa0) @memset(text[i..][0..n], '?');
            i += n;
        } else {
            if (c < 0xa0) text[i] = '?';
            i += 1;
        }
    }
}

test "control characters are masked" {
    var text = "a\x1b[2J\n\tb\r\nc\r\x7f \u{9b}\u{e9}\u{20ac}\x9b\xe9".*;
    var layout = text;
    maskControls(&text, false);
    try std.testing.expectEqualStrings("a?[2J??b??c?? ??\u{e9}\u{20ac}?\xe9", &text);
    maskControls(&layout, true);
    try std.testing.expectEqualStrings("a?[2J\n\tb\r\nc?? ??\u{e9}\u{20ac}?\xe9", &layout);
}

/// Room for a record's strings while they are masked.
pub const MaskBuffer = [32 + 32 + host_size + 4]u8;

/// `r` with the control characters of its strings masked, copied into `buf`.
pub fn masked(r: Record, buf: *MaskBuffer) Record {
    var out = r;
    var at: usize = 0;
    inline for (.{ "user", "line", "host", "id" }) |name| {
        const from = @field(r, name);
        const to = buf[at..][0..from.len];
        @memcpy(to, from);
        maskControls(to, false);
        @field(out, name) = to;
        at += from.len;
    }
    return out;
}

fn field(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

/// Decode record `index` of `data`; null past the last whole record.
pub fn record(data: []const u8, index: usize) ?Record {
    return recordIn(native, data, index);
}

/// `record` for a file written with another architecture's layout.
pub fn recordIn(layout: Layout, data: []const u8, index: usize) ?Record {
    const start = std.math.mul(usize, index, layout.size) catch return null;
    if (start > data.len or data.len - start < layout.size) return null;
    const r = data[start..][0..layout.size];
    const endian = builtin.cpu.arch.endian();
    const addr_at: usize = if (layout.wide) 360 else 348;
    var addr: [4]u32 = undefined;
    for (&addr, 0..) |*a, n| a.* = std.mem.readInt(u32, r[addr_at + 4 * n ..][0..4], endian);
    return .{
        .kind = @fromBackingInt(@intCast(std.mem.readInt(i16, r[0..2], endian))),
        .pid = std.mem.readInt(i32, r[4..8], endian),
        .line = field(r[8..40]),
        .id = r[40..44], // not NUL-terminated by definition; trimmed on use
        .user = field(r[44..76]),
        .host = field(r[76..][0..host_size]),
        .exit_termination = std.mem.readInt(i16, r[332..334], endian),
        .exit_status = std.mem.readInt(i16, r[334..336], endian),
        .session = if (layout.wide) @truncate(std.mem.readInt(i64, r[336..344], endian)) else std.mem.readInt(i32, r[336..340], endian),
        .time = if (layout.wide) std.mem.readInt(i64, r[344..352], endian) else std.mem.readInt(i32, r[340..344], endian),
        .addr = addr,
    };
}

/// Store the seconds of a record being built (for tests and fixtures).
pub fn putTime(layout: Layout, rec: []u8, seconds: i32) void {
    const endian = builtin.cpu.arch.endian();
    if (layout.wide) std.mem.writeInt(i64, rec[344..352], seconds, endian) else std.mem.writeInt(i32, rec[340..344], seconds, endian);
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
    putTime(native, &buf, 1762500000);
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

test "both record layouts, whatever this is built for" {
    const t = std.testing;
    const endian = builtin.cpu.arch.endian();
    try t.expectEqual(@as(usize, 384), Layout.of(.x86_64).size);
    try t.expectEqual(@as(usize, 384), Layout.of(.riscv64).size);
    try t.expectEqual(@as(usize, 384), Layout.of(.arm).size);
    try t.expectEqual(@as(usize, 400), Layout.of(.aarch64).size);
    try t.expectEqual(@as(usize, 400), Layout.of(.loongarch64).size);
    inline for (.{ Layout.compat, Layout.wide64 }) |layout| {
        var data: [3 * layout.size]u8 = @splat(0);
        for ([_][]const u8{ "alice", "bob", "carol" }, 0..) |name, n| {
            const r = data[n * layout.size ..][0..layout.size];
            std.mem.writeInt(i16, r[0..2], 7, endian);
            @memcpy(r[44..][0..name.len], name);
            putTime(layout, r, 1700000000 + @as(i32, @intCast(n)));
            std.mem.writeInt(u32, r[if (layout.wide) 360 else 348..][0..4], 0x0100007f, endian);
        }
        const third = recordIn(layout, &data, 2).?;
        try t.expectEqualStrings("carol", third.user);
        try t.expectEqual(@as(i64, 1700000002), third.time);
        try t.expectEqual(@as(u32, 0x0100007f), third.addr[0]);
        try t.expect(recordIn(layout, &data, 3) == null);
    }
}
