// SPDX-License-Identifier: GPL-2.0-or-later
//! id: thin wrapper over `util_unix.identity`.
//!
//! Names come from /etc/passwd and /etc/group only (decision 0004). SELinux
//! contexts are not supported: -Z reports that, as GNU does on a kernel
//! without SELinux.
//! References: POSIX.1-2024 id; GNU coreutils 9.7 "id invocation".

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cli = @import("../cli.zig");
const shared = @import("../identity_cli.zig");

const long_names = [_][]const u8{ "context", "group", "groups", "name", "real", "user", "zero", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var user = false;
    var group = false;
    var groups = false;
    var names = false;
    var real = false;
    var zero = false;
    var context = false;
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
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, &long_names, m);
                    return 1;
                },
            };
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => context = true,
                1 => group = true,
                2 => groups = true,
                3 => names = true,
                4 => real = true,
                5 => user = true,
                6 => zero = true,
                7 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'a' => {},
            'Z' => context = true,
            'g' => group = true,
            'G' => groups = true,
            'n' => names = true,
            'r' => real = true,
            'u' => user = true,
            'z' => zero = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    const only_one = @as(u8, @intFromBool(user)) + @intFromBool(group) + @intFromBool(groups);
    if (only_one > 1) {
        cli.warn(ctx, "cannot print \"only\" of more than one choice", .{});
        return 1;
    }
    if (only_one == 0 and !context and (names or real)) {
        cli.warn(ctx, "printing only names or real IDs requires -u, -g, or -G", .{});
        return 1;
    }
    if (only_one == 0 and !context and zero) {
        cli.warn(ctx, "option --zero not permitted in default format", .{});
        return 1;
    }
    if (context) {
        cli.warn(ctx, "--context (-Z) works only on an SELinux-enabled kernel", .{});
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
    const opts: uu.identity.Options = .{
        .which = if (user) .user else if (group) .group else if (groups) .groups else .default,
        .names = names,
        .real = real,
        .zero = zero,
        .unnamed = shared.unnamedWarning(&ctx),
    };

    var status: u8 = 0;
    if (users.items.len == 0) {
        const me = uu.proc.identity();
        const sup = uu.proc.supplementaryGroups(ctx.gpa) catch {
            cli.warn(ctx, "cannot get the supplementary groups of the process", .{});
            return 1;
        };
        defer ctx.gpa.free(sup);
        const ids: uu.identity.Ids = .{ .uid = me.uid, .euid = me.euid, .gid = me.gid, .egid = me.egid, .groups = sup };
        if (!(uu.identity.write(w, &db, opts, ids) catch return 1)) status = 1;
    } else for (users.items) |name| {
        const pw = uu.identity.findUser(&db, name) orelse {
            w.flush() catch {};
            cli.warn(ctx, "{f}: no such user", .{cli.quoteC(name)});
            status = 1;
            continue;
        };
        const ids = uu.identity.idsOfUser(&db, pw) catch return 1;
        defer ctx.gpa.free(ids.groups);
        if (!(uu.identity.write(w, &db, opts, ids) catch return 1)) status = 1;
    }
    w.flush() catch return 1;
    return status;
}

const help_text = "Usage: id [OPTION]... [USER]...\n" ++
    "Print user and group information for each specified USER,\n" ++
    "or (when USER omitted) for the current process.\n\n" ++
    "  -a             ignore, for compatibility with other versions\n" ++
    "  -Z, --context  print only the security context of the process\n" ++
    "  -g, --group    print only the effective group ID\n" ++
    "  -G, --groups   print all group IDs\n" ++
    "  -n, --name     print a name instead of a number, for -u,-g,-G\n" ++
    "  -r, --real     print the real ID instead of the effective ID, with -u,-g,-G\n" ++
    "  -u, --user     print only the effective user ID\n" ++
    "  -z, --zero     delimit entries with NUL characters, not whitespace;\n" ++
    "                   not permitted in default format\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n\n" ++
    "Without any OPTION, print some useful set of identified information.\n";
