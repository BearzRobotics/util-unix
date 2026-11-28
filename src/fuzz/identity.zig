// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: id/groups formatting (lib/identity.zig) for arbitrary ids and databases.
//! Invariants: no crash, no leak; text output ends in its terminator; JSON output
//! always parses.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const identity = uu.identity;
const userdb = uu.userdb;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

const Unnamed = struct {
    n: usize = 0,
    fn on(ctx: ?*anyopaque, _: identity.Kind, _: u32) void {
        const u: *Unnamed = @ptrCast(@alignCast(ctx.?));
        u.n += 1;
    }
};

fn run(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var pbuf: [384]u8 = undefined;
    var gbuf: [384]u8 = undefined;
    var kbuf: [32]u8 = undefined;
    const passwd = pbuf[0..smith.slice(&pbuf)];
    const group = gbuf[0..smith.slice(&gbuf)];
    const key = kbuf[0..smith.slice(&kbuf)];
    var groups_buf: [6]u32 = undefined;
    for (&groups_buf) |*g| g.* = smith.value(u32);
    const ngroups = smith.value(u8) % (groups_buf.len + 1);
    const ids: identity.Ids = .{
        .uid = smith.value(u32),
        .euid = smith.value(u32),
        .gid = smith.value(u32),
        .egid = smith.value(u32),
        .groups = groups_buf[0..ngroups],
    };

    var db = try userdb.Db.fromText(gpa, passwd, group);
    defer db.deinit();

    var unnamed: Unnamed = .{};
    for ([_]identity.Which{ .default, .user, .group, .groups }) |which| {
        for (0..8) |flags| {
            const opts: identity.Options = .{
                .which = which,
                .names = flags & 1 != 0,
                .real = flags & 2 != 0,
                .zero = flags & 4 != 0,
                .unnamed = .{ .context = &unnamed, .on_unnamed = Unnamed.on },
            };
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            _ = try identity.write(&out.writer, &db, opts, ids);
            const text = out.written();
            try std.testing.expect(text.len > 0);
            try std.testing.expectEqual(@as(u8, if (which != .default and opts.zero) 0 else '\n'), text[text.len - 1]);
        }
    }

    var j: Io.Writer.Allocating = .init(gpa);
    defer j.deinit();
    try identity.writeJson(&j.writer, &db, ids);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, j.written(), .{});
    parsed.deinit();

    if (identity.findUser(&db, key)) |pw| {
        const found = try identity.idsOfUser(&db, pw);
        defer gpa.free(found.groups);
        try std.testing.expectEqual(pw.gid, found.groups[0]);
        var j2: Io.Writer.Allocating = .init(gpa);
        defer j2.deinit();
        try identity.writeJson(&j2.writer, &db, found);
        var p2 = try std.json.parseFromSlice(std.json.Value, gpa, j2.written(), .{});
        p2.deinit();
    }
}

const sample_passwd = "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/h:/bin/sh\nq\"uote:x:5:5::/:/bin/sh\n";
const sample_group = "root:x:0:\nadm:x:4:alice\nalice:x:1000:\nweird\\:x:7:alice\n";

test "fuzz: id formatting" {
    try engine.fuzz({}, seed_mod.capped(void, run), .{ .name = "identity-run", .corpus = &.{
        seed(.{ sample_passwd, sample_group, "alice" }),
        seed(.{ sample_passwd, sample_group, "0" }),
        seed(.{ sample_passwd, sample_group, "nosuch" }),
        seed(.{ "", "", "" }),
        seed(.{ "\xff:x:1:1::/:/\n", "\xfe:x:1:\n", "\xff" }),
    } });
}
