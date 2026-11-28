// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: SELinux context strings (lib/selinux.zig `edit`) and the chcon walk
//! (lib/chcon.zig) on a tree in std.testing.tmpDir. Invariants: no crash, no leak, no
//! hang (symbolic-link cycles included); an edited context keeps the
//! `user:role:type[:range]` shape and holds the components that were asked for.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const selinux = uu.selinux;
const chcon = uu.chcon;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn editRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var cbuf: [96]u8 = undefined;
    var bufs: [4][24]u8 = undefined;
    const context = cbuf[0..smith.slice(&cbuf)];
    var parts: [4][]const u8 = undefined;
    for (&parts, &bufs) |*p, *b| p.* = b[0..smith.slice(b)];
    const present = smith.value(u8);
    const c: selinux.Components = .{
        .user = if (present & 1 != 0) parts[0] else null,
        .role = if (present & 2 != 0) parts[1] else null,
        .type = if (present & 4 != 0) parts[2] else null,
        .range = if (present & 8 != 0) parts[3] else null,
    };
    var diag: selinux.Edit = .{};
    if (selinux.edit(gpa, context, c, &diag)) |new| {
        defer gpa.free(new);
        try std.testing.expect(std.mem.count(u8, new, ":") >= 2);
        if (c.user) |u| try std.testing.expect(std.mem.startsWith(u8, new, u));
        if (c.range) |r| try std.testing.expect(std.mem.endsWith(u8, new, r));
    } else |e| switch (e) {
        error.BadComponent => try std.testing.expect(diag.bad != null),
        else => {},
    }
}

const Count = struct {
    n: usize = 0,
    fn on(ctx: ?*anyopaque, _: chcon.Event) void {
        const c: *Count = @ptrCast(@alignCast(ctx.?));
        c.n += 1;
    }
};

fn chconRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "d/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "d/sub/b", .data = "x" });
    tmp.dir.symLink(io, "..", "d/sub/up", .{}) catch {};
    tmp.dir.symLink(io, "nowhere", "dangling", .{}) catch {};

    var pathbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, ".", &pathbuf);
    const root = pathbuf[0..n];
    var operands: [4][]const u8 = undefined;
    var storage: [4][Io.Dir.max_path_bytes + 16]u8 = undefined;
    for (&operands, &storage, [_][]const u8{ "f", "d", "dangling", "missing" }) |*o, *s, rel|
        o.* = try std.fmt.bufPrint(s, "{s}/{s}", .{ root, rel });

    var ctx_buf: [48]u8 = undefined;
    const ctx = ctx_buf[0..smith.slice(&ctx_buf)];
    var user_buf: [16]u8 = undefined;
    const user = user_buf[0..smith.slice(&user_buf)];
    const bits = smith.value(u8);
    var count: Count = .{};
    const opts: chcon.Options = .{
        .target = if (bits & 1 != 0) .{ .full = ctx } else .{ .partial = .{ .user = user, .type = if (bits & 2 != 0) ctx else null } },
        .recurse = bits & 4 != 0,
        .traversal = switch ((bits >> 3) % 3) {
            0 => .physical,
            1 => .command_line,
            else => .logical,
        },
        .dereference = bits & 64 != 0,
        .verbose = bits & 128 != 0,
        .reporter = .{ .context = &count, .on_event = Count.on },
    };
    _ = try chcon.run(io, gpa, opts, &operands);
}

test "fuzz: SELinux context editing" {
    try engine.fuzz({}, seed_mod.capped(void, editRun), .{ .name = "selinux-editRun", .corpus = &.{
        seed(.{ "unconfined_u:object_r:user_home_t:s0", "u", "r", "t", "s0" }),
        seed(.{ "u:r:t", "", "", "", "" }),
        seed(.{ "u:r:t:s0:c1,c2", "x:y", "", "", "s0-s0:c0.c1023" }),
        seed(.{ "::", "", "", "", "" }),
        seed(.{ "", "", "", "", "" }),
        seed(.{ "a:b", "", "", "", "" }),
    } });
}

test "fuzz: chcon on a tree" {
    try engine.fuzz({}, seed_mod.capped(void, chconRun), .{ .name = "selinux-chconRun", .corpus = &.{
        seed(.{ "system_u:object_r:tmp_t:s0", "u" }),
        seed(.{ "", "" }),
        seed(.{ "a:b:c", "x:y" }),
    } });
}
