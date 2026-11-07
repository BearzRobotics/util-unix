// SPDX-License-Identifier: GPL-2.0-or-later
//! who: thin wrapper over `util_unix.who`.
//!
//! References: POSIX.1-2024 who; GNU coreutils 9.7 "who invocation". Exit
//! status 0 on success, 1 on a usage or write error. A utmp file that does not
//! exist is treated as empty (GNU 9.7 does the same here).
//!
//! Not supported: systemd-logind sessions; --lookup does nothing.

const std = @import("std");
const Io = std.Io;
const uu = @import("util_unix");
const cli = @import("../cli.zig");

const long_names = [_][]const u8{
    "all",      "boot",  "dead", "heading", "login",   "lookup",   "process", "count",
    "runlevel", "short", "time", "mesg",    "message", "writable", "users",   "help",
    "version",
};

pub fn main(ctx: cli.Context) u8 {
    var o: uu.who.Options = .{ .now = 0 };
    var heading = false;
    var operands: [3][]const u8 = undefined;
    var n_operands: usize = 0;
    var only_operands = false;

    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (n_operands < 3) operands[n_operands] = a;
            n_operands += 1;
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
                0 => all(&o),
                1 => o.boot = true,
                2 => dead(&o),
                3 => heading = true,
                4 => login(&o),
                5 => {},
                6 => o.init_spawn = true,
                7 => o.count = true,
                8 => runlevel(&o),
                9 => o.short = true,
                10 => o.clock_change = true,
                11, 12, 13 => o.include_mesg = true,
                14 => users(&o),
                15 => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'a' => all(&o),
            'b' => o.boot = true,
            'd' => dead(&o),
            'H' => heading = true,
            'l' => login(&o),
            'm' => mine(&o),
            'p' => o.init_spawn = true,
            'q' => o.count = true,
            'r' => runlevel(&o),
            's' => o.short = true,
            't' => o.clock_change = true,
            'T', 'w' => o.include_mesg = true,
            'u' => users(&o),
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    if (n_operands > 2) {
        cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteaf(operands[2]), ctx.name });
        return 1;
    }
    if (n_operands == 2) mine(&o);
    o.heading = heading;
    o.finish();
    o.now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    o.style = uu.who.styleForLocale(cli.getenv(ctx, "LC_ALL"), cli.getenv(ctx, "LC_TIME"), cli.getenv(ctx, "LANG"));

    var line_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (o.my_line_only) {
        if (uu.tty.name(ctx.io, Io.File.stdin(), &line_buf)) |full| {
            o.my_line = if (std.mem.startsWith(u8, full, "/dev/")) full[5..] else full;
        }
    }

    const path: []const u8 = if (n_operands == 1) operands[0] else uu.utmp.default_path;
    const data = uu.utmp.load(ctx.io, ctx.gpa, path) catch |e| switch (e) {
        error.FileNotFound => ctx.gpa.alloc(u8, 0) catch return 1,
        else => {
            cli.warn(ctx, "{f}: {s}", .{ cli.quotef(path), cli.errText(e) });
            return 1;
        },
    };
    defer ctx.gpa.free(data);

    var zone = uu.localtime.Zone.load(ctx.io, ctx.gpa, cli.getenv(ctx, "TZ"));
    defer zone.deinit();
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(ctx.io, &buf);
    uu.who.write(ctx.io, &w.interface, data, &zone, o) catch return 1;
    w.interface.flush() catch return 1;
    return 0;
}

fn all(o: *uu.who.Options) void {
    o.boot = true;
    o.init_spawn = true;
    o.runlevel = true;
    o.clock_change = true;
    o.include_mesg = true;
    dead(o);
    login(o);
    users(o);
}

fn runlevel(o: *uu.who.Options) void {
    o.runlevel = true;
    o.include_idle = true;
}

/// -m, "am i": only the entry for the terminal on standard input, in short form.
fn mine(o: *uu.who.Options) void {
    o.my_line_only = true;
    o.users = true;
    o.short = true;
}

fn dead(o: *uu.who.Options) void {
    o.dead = true;
    o.include_idle = true;
    o.include_exit = true;
}

fn login(o: *uu.who.Options) void {
    o.login = true;
    o.include_idle = true;
}

fn users(o: *uu.who.Options) void {
    o.users = true;
    o.include_idle = true;
}

const help_text = "Usage: who [OPTION]... [ FILE | ARG1 ARG2 ]\n" ++
    "Print information about users who are currently logged in.\n\n" ++
    "  -a, --all         same as -b -d --login -p -r -t -T -u\n" ++
    "  -b, --boot        time of last system boot\n" ++
    "  -d, --dead        print dead processes\n" ++
    "  -H, --heading     print line of column headings\n" ++
    "  -l, --login       print system login processes\n" ++
    "      --lookup      attempt to canonicalize hostnames via DNS\n" ++
    "  -m                only hostname and user associated with stdin\n" ++
    "  -p, --process     print active processes spawned by init\n" ++
    "  -q, --count       all login names and number of users logged on\n" ++
    "  -r, --runlevel    print current runlevel\n" ++
    "  -s, --short       print only name, line, and time (default)\n" ++
    "  -t, --time        print last system clock change\n" ++
    "  -T, -w, --mesg    add user's message status as +, - or ?\n" ++
    "  -u, --users       list users logged in\n" ++
    "      --message     same as -T\n" ++
    "      --writable    same as -T\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n\n" ++
    "If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.\n" ++
    "If ARG1 ARG2 given, -m presumed: 'am i' or 'mom likes' are usual.\n";
