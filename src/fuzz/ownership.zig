// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: chown/chgrp (lib/ownership.zig) and the file-system layer under them
//! (lib/fsown.zig), driven with arbitrary option vectors against a tree in
//! std.testing.tmpDir. The owner and group are only ever null or the caller's own, so
//! no change is possible beyond what the caller already owns. Invariants: no crash,
//! no hang (symbolic-link cycles included), no leak.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const ownership = uu.ownership;
const fsown = uu.fsown;
const userdb = uu.userdb;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

const Count = struct {
    events: usize = 0,
    fn on(ctx: ?*anyopaque, ev: ownership.Event) void {
        const c: *Count = @ptrCast(@alignCast(ctx.?));
        c.events += 1;
        switch (ev) {
            .change => |ch| std.debug.assert(ch.old_user == null or ch.old_user.?.len > 0),
            .problem => {},
        }
    }
};

fn makeTree(dir: Io.Dir) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, "d/sub");
    try dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "d/a", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "d/sub/b", .data = "x" });
    dir.symLink(io, "f", "link", .{}) catch {};
    dir.symLink(io, "../f", "d/inner", .{}) catch {};
    dir.symLink(io, "..", "d/sub/up", .{}) catch {};
    dir.symLink(io, "sub", "d/down", .{}) catch {};
    dir.symLink(io, "nowhere", "dangling", .{}) catch {};
}

fn ownershipRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir);

    const me = try uu.proc.identity();
    const bits = smith.value(u32);
    var nbuf: [24]u8 = undefined;
    var gbuf: [24]u8 = undefined;
    const user_name = nbuf[0..smith.slice(&nbuf)];
    const group_name = gbuf[0..smith.slice(&gbuf)];

    var db = try userdb.Db.fromText(gpa, "me:x:1000:1000::/:/bin/sh\n", "me:x:1000:\n");
    defer db.deinit();

    const operands = [_][]const u8{ "f", "d", "link", "dangling", "d/sub", "nope", "d/", "d/sub/up", "d//", "" };
    const operand = operands[bits % operands.len];
    const root_stat: ?fsown.Stat = if (bits & (1 << 4) != 0) fsown.statAt(tmp.dir, "d", true) catch null else null;

    var count: Count = .{};
    const opts: ownership.Options = .{
        // Only ever the caller's own ids (or the other, "unchanged").
        .uid = if (bits & (1 << 5) != 0) me.uid else null,
        .gid = if (bits & (1 << 6) != 0) me.gid else null,
        // --from: matches the caller, or nobody.
        .required_uid = switch ((bits >> 7) & 3) {
            0 => null,
            1 => me.uid,
            else => me.uid +% 1,
        },
        .required_gid = switch ((bits >> 9) & 3) {
            0 => null,
            1 => me.gid,
            else => me.gid +% 1,
        },
        .recurse = bits & (1 << 11) != 0,
        .traversal = switch ((bits >> 12) % 3) {
            0 => .physical,
            1 => .command_line,
            else => .logical,
        },
        .dereference = bits & (1 << 14) != 0,
        .verbosity = switch ((bits >> 15) % 3) {
            0 => .off,
            1 => .changes,
            else => .verbose,
        },
        .quiet = bits & (1 << 17) != 0,
        .preserve_root = root_stat,
        .user_name = if (bits & (1 << 18) != 0) user_name else null,
        .group_name = if (bits & (1 << 19) != 0) group_name else null,
        .db = &db,
        .reporter = .{ .context = &count, .on_event = Count.on },
        .base = tmp.dir,
    };
    _ = try ownership.run(std.testing.io, gpa, opts, &.{operand});
    // The whole tree, every link followed, with the other traversal rules as well.
    var all = opts;
    all.recurse = true;
    all.traversal = .logical;
    all.preserve_root = null;
    all.uid = me.uid;
    all.gid = me.gid;
    _ = try ownership.run(std.testing.io, gpa, all, &.{ "d", "link", "nope" });
}

fn fsownRun(_: void, smith: *std.testing.Smith, _: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTree(tmp.dir);
    var nbuf: [96]u8 = undefined;
    const name = nbuf[0..smith.slice(&nbuf)];
    const follow = smith.value(bool);
    if (fsown.statAt(tmp.dir, name, follow)) |s| {
        _ = s.isDir();
        _ = s.isReg();
        _ = s.isLink();
        _ = s.sameFile(s);
    } else |_| {}
    // (uid_t)-1 and (gid_t)-1: nothing changes, whatever the name resolves to.
    fsown.chownAt(tmp.dir, name, null, null, follow) catch {};
}

test "fuzz: chown and chgrp option vectors on a tree" {
    try engine.fuzz({}, seed_mod.capped(void, ownershipRun), .{ .name = "ownership-ownershipRun", .corpus = &.{
        seed(.{ "", "" }),
        seed(.{ "me", "me" }),
        seed(.{ "\x00", "\xff" }),
    } });
}

test "fuzz: fsown names" {
    try engine.fuzz({}, seed_mod.capped(void, fsownRun), .{ .name = "ownership-fsownRun", .corpus = &.{
        seed(.{"f"}),
        seed(.{"d/sub/up/sub/up"}),
        seed(.{"link"}),
        seed(.{"dangling"}),
        seed(.{"d//sub/"}),
        seed(.{"a\x00b"}),
        seed(.{""}),
        seed(.{&@as([96]u8, @splat('x'))}),
    } });
}
