// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: every getent database (lib/getent.zig) with arbitrary file contents and
//! keys. The same file text is queried through every database, with and without a key,
//! so each parser sees every kind of input. Invariants: no crash, no leak, no hang;
//! "found" means output, "not found" means none, and output is whole lines.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const getent = uu.getent;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

const Ctx = struct {
    tmp: std.testing.TmpDir,
};

fn query(ctx: *Ctx, gpa: std.mem.Allocator, db: getent.Database, key: ?[]const u8, out: *Io.Writer.Allocating) !getent.Outcome {
    return getent.query(std.testing.io, gpa, db, key, .{
        .path = "data",
        .dir = ctx.tmp.dir,
    }, &out.writer);
}

fn allDatabases(ctx: *Ctx, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var tbuf: [1536]u8 = undefined;
    var kbuf: [48]u8 = undefined;
    const text = tbuf[0..smith.slice(&tbuf)];
    const key = kbuf[0..smith.slice(&kbuf)];
    try ctx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data", .data = text });

    for (std.enums.values(getent.Database)) |db| {
        for ([2]?[]const u8{ key, null }) |k| {
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const outcome = try query(ctx, gpa, db, k, &out);
            const got = out.written();
            switch (outcome) {
                .found => try std.testing.expect(got.len > 0),
                .not_found, .enumeration_unsupported => try std.testing.expectEqual(@as(usize, 0), got.len),
            }
            if (got.len > 0) try std.testing.expectEqual(@as(u8, '\n'), got[got.len - 1]);
            // A key selects one entry (ahosts prints three lines for it).
            if (k != null and db != .ahosts and db != .ahostsv4 and db != .ahostsv6 and db != .initgroups) {
                try std.testing.expect(std.mem.count(u8, got, "\n") <= 1);
            }
        }
    }
}

fn run(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var ctx: Ctx = .{ .tmp = std.testing.tmpDir(.{}) };
    defer ctx.tmp.cleanup();
    try allDatabases(&ctx, smith, gpa);
}

const hosts = "127.0.0.1 localhost\n::1 ip6-localhost ip6-loopback # c\n10.0.0.1 a b\nfe00::0 net\n::ffff:1.2.3.4 m\n1.2.3 bad\n";
const services = "# c\necho 7/tcp\nhttp 80/tcp www # web\ndomain 53/udp\nx 99999999999/tcp\nbad\nbad 1\n";
const networks = "loopback 127.0.0.0\nlink-local 169.254.0.0\nweird 1.2.3.4.5\nclassa 10\nclassb 172.16\n";
const protocols = "ip 0 IP\nicmp 1 ICMP\ntcp 6 TCP\nneg -5 N\nhuge 99999999999999999999 H\n";
const ethers = "00:11:22:33:44:55 host1\n1:2:3:4:5:6 h2\n1:2:3:4:5:6:7 h3\nzz:1:1:1:1:1 h4\n";
const aliases = "postmaster: root\nMAILER-DAEMON: postmaster\nlist: a, b,c  d\n:x\nnocolon\n";
const shadow = "root:$6$x:19000:0:99999:7:::\nalice:!:abc:::::\n:::\nbob\n";
const groups = "adm:x:4:alice,bob\nalice:x:1000:\nusers:x:100:alice\n";

test "fuzz: every getent database on arbitrary file text and keys" {
    try engine.fuzz({}, seed_mod.capped(void, run), .{ .name = "getent-run", .corpus = &.{
        seed(.{ hosts, "localhost" }),
        seed(.{ hosts, "::1" }),
        seed(.{ hosts, "10.0.0.1" }),
        seed(.{ services, "http/tcp" }),
        seed(.{ services, "53/udp" }),
        seed(.{ networks, "127" }),
        seed(.{ networks, "10.0.0.0" }),
        seed(.{ protocols, "ICMP" }),
        seed(.{ protocols, "6" }),
        seed(.{ ethers, "0:11:22:33:44:55" }),
        seed(.{ ethers, "host1" }),
        seed(.{ aliases, "list" }),
        seed(.{ shadow, "root" }),
        seed(.{ groups, "alice" }),
        seed(.{ "root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/h:/bin/sh\n", "0" }),
        seed(.{ "", "" }),
        seed(.{ "\x00\xff\n\n#\n:::\n\t\t\n", "\x00" }),
    } });
}
