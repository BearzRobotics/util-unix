// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: chown OWNER:GROUP specs (lib/userspec.zig) against arbitrary passwd and
//! group text. Invariants: no crash, no leak; a parsed id is never the "unchanged"
//! sentinel 2^32-1; a name that is reported was resolved in the database.

const std = @import("std");
const uu = @import("util_unix");
const userspec = uu.userspec;
const userdb = uu.userdb;
const seed_mod = @import("seed.zig");
const seed = seed_mod.seed;
const engine = @import("engine.zig");

fn specRun(_: void, smith: *std.testing.Smith, gpa: std.mem.Allocator) anyerror!void {
    var pbuf: [256]u8 = undefined;
    var gbuf: [256]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    const pw_text = pbuf[0..smith.slice(&pbuf)];
    const gr_text = gbuf[0..smith.slice(&gbuf)];
    const spec = sbuf[0..smith.slice(&sbuf)];

    var db = try userdb.Db.fromText(gpa, pw_text, gr_text);
    defer db.deinit();

    inline for (.{ userspec.Mode.user_and_group, userspec.Mode.user_only }) |m| {
        if (userspec.parse(&db, spec, m)) |p| {
            if (p.uid) |u| try std.testing.expect(u != std.math.maxInt(u32));
            if (p.gid) |g| try std.testing.expect(g != std.math.maxInt(u32));
            if (p.user_name) |n| try std.testing.expect(db.userByName(n) != null);
            if (m == .user_only) try std.testing.expect(!p.warn_dot and p.gid == null);
        } else |e| try std.testing.expect(userspec.errorText(e).len > 0);
    }
}

const sample_passwd = "root:x:0:0:root:/root:/bin/bash\nalice:x:1000:100:Alice:/home/alice:/bin/sh\n1234:x:77:77::/:/bin/false\ndot.user:x:2000:2000::/:/bin/sh\n";
const sample_group = "root:x:0:\nusers:x:100:alice\nalice:x:1000:\n5678:x:88:\n";

test "fuzz: user:group specs" {
    try engine.fuzz({}, seed_mod.capped(void, specRun), .{ .name = "userspec-specRun", .corpus = &.{
        seed(.{ sample_passwd, sample_group, "alice:users" }),
        seed(.{ sample_passwd, sample_group, "alice:" }),
        seed(.{ sample_passwd, sample_group, ":users" }),
        seed(.{ sample_passwd, sample_group, ":" }),
        seed(.{ sample_passwd, sample_group, "" }),
        seed(.{ sample_passwd, sample_group, "1234" }),
        seed(.{ sample_passwd, sample_group, "+1234:+5678" }),
        seed(.{ sample_passwd, sample_group, "dot.user" }),
        seed(.{ sample_passwd, sample_group, "alice.users" }),
        seed(.{ sample_passwd, sample_group, "4294967295" }),
        seed(.{ sample_passwd, sample_group, "4294967294:4294967296" }),
        seed(.{ sample_passwd, sample_group, " 12:\t5" }),
        seed(.{ "", "", "a:b:c" }),
    } });
}
