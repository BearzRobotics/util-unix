// SPDX-License-Identifier: GPL-2.0-or-later
//! pinky: thin wrapper over `util_unix.pinky`.
//!
//! References: GNU coreutils 9.7 "pinky invocation". Exit status 0, or 1 on a
//! usage error. The utmp file is /var/run/utmp (no option to change it, as in
//! GNU); systemd-logind sessions are not read.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "lookup", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var o: uu.pinky.Options = .{ .now = 0 };
    var users = std.ArrayList([]const u8).empty;
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
                0 => {},
                1 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'l' => o.long = true,
            's' => o.long = false,
            'b' => o.home_and_shell = false,
            'h' => o.project = false,
            'p' => o.plan = false,
            'f' => o.heading = false,
            'w' => o.fullname = false,
            'i' => {
                o.fullname = false;
                o.where = false;
            },
            'q' => {
                o.fullname = false;
                o.where = false;
                o.idle = false;
            },
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    if (o.long and users.items.len == 0) {
        cli.warn(ctx, "no username specified; at least one must be specified when using -l\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    o.now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    o.style = uu.who.styleForLocale(cli.getenv(ctx, "LC_ALL"), cli.getenv(ctx, "LC_TIME"), cli.getenv(ctx, "LANG"));
    var db = uu.userdb.Db.load(ctx.io, ctx.gpa, .{}) catch {
        cli.warn(ctx, "cannot read the account database", .{});
        return 1;
    };
    defer db.deinit();
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const out = &w.interface;

    if (o.long) {
        for (users.items) |u| {
            uu.pinky.writeLong(ctx.io, ctx.gpa, out, &db, u, o) catch return 1;
        }
    } else {
        const data = uu.utmp.load(ctx.io, ctx.gpa, uu.utmp.default_path) catch ctx.gpa.alloc(u8, 0) catch return 1;
        defer ctx.gpa.free(data);
        var zone = uu.localtime.Zone.load(ctx.io, ctx.gpa, cli.getenv(ctx, "TZ"));
        defer zone.deinit();
        uu.pinky.writeShort(ctx.io, out, data, &zone, &db, users.items, o) catch return 1;
    }
    out.flush() catch return 1;
    return 0;
}

const help_text = "Usage: pinky [OPTION]... [USER]...\n\n" ++
    "  -l              produce long format output for the specified USERs\n" ++
    "  -b              omit the user's home directory and shell in long format\n" ++
    "  -h              omit the user's project file in long format\n" ++
    "  -p              omit the user's plan file in long format\n" ++
    "  -s              do short format output, this is the default\n" ++
    "  -f              omit the line of column headings in short format\n" ++
    "  -w              omit the user's full name in short format\n" ++
    "  -i              omit the user's full name and remote host in short format\n" ++
    "  -q              omit the user's full name, remote host and idle time\n" ++
    "                  in short format\n" ++
    "      --lookup    attempt to canonicalize hostnames via DNS\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n\n" ++
    "A lightweight 'finger' program;  print user information.\n" ++
    "The utmp file will be /var/run/utmp.\n";
