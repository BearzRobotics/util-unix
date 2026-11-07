// SPDX-License-Identifier: GPL-2.0-or-later
//! groups: thin wrapper over `util_unix.identity`.
//!
//! Same data as `id -Gn`; with user names each line is prefixed by `NAME : `.
//! Reference: GNU coreutils 9.7 "groups invocation".

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cli = @import("../cli.zig");
const shared = @import("../identity_cli.zig");

pub fn main(ctx: cli.Context) u8 {
    var users: std.ArrayList([]const u8) = .empty;
    defer users.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            users.append(ctx.gpa, a) catch return 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &.{ "help", "version" });
            switch (m) {
                .found => |k| return if (k == 0) (if (cli.writeStdout(ctx.io, help_text)) 0 else 1) else if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, &.{ "help", "version" }, m);
                    return 1;
                },
            }
        }
        cli.invalidShort(ctx, a[1]);
        return 1;
    }

    var db = uu.userdb.Db.load(ctx.io, ctx.gpa, .{}) catch {
        cli.warn(ctx, "cannot read the user and group databases", .{});
        return 1;
    };
    defer db.deinit();
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    const opts: uu.identity.Options = .{ .which = .groups, .names = true, .unnamed = shared.unnamedWarning(&ctx) };

    var status: u8 = 0;
    if (users.items.len == 0) {
        const me = uu.proc.identity();
        const sup = uu.proc.supplementaryGroups(ctx.gpa) catch {
            cli.warn(ctx, "cannot get the supplementary groups of the process", .{});
            return 1;
        };
        defer ctx.gpa.free(sup);
        const ids: uu.identity.Ids = .{ .uid = me.uid, .euid = me.euid, .gid = me.gid, .egid = me.egid, .groups = sup };
        const ok = uu.identity.write(w, &db, opts, ids) catch return 1;
        if (!ok) status = 1;
    } else for (users.items) |name| {
        const pw = db.userByName(name) orelse {
            w.flush() catch {};
            cli.warn(ctx, "{f}: no such user", .{cli.quoteC(name)});
            status = 1;
            continue;
        };
        const ids = uu.identity.idsOfUser(&db, pw) catch return 1;
        defer ctx.gpa.free(ids.groups);
        w.print("{s} : ", .{name}) catch return 1;
        const ok = uu.identity.write(w, &db, opts, ids) catch return 1;
        if (!ok) status = 1;
    }
    w.flush() catch return 1;
    return status;
}

const help_text = "Usage: groups [OPTION]... [USERNAME]...\n" ++
    "Print group memberships for each USERNAME or, if no USERNAME is specified, for\n" ++
    "the current process (which may differ if the groups database has changed).\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n";
